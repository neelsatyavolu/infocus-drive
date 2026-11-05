import Foundation
import UniformTypeIdentifiers

/// A-roll/B-roll downloads (`GET api/package-cycle/a-roll/<rowId>/download?id=…`, the web's
/// `clipDownloadHref`). One clip redirects to its signed original on InFocus Drive; several, or no
/// ids (every ready clip), stream one zip with A-roll/ and B-roll/ folders. A zip can reach 40 GB,
/// so the answer streams to a file on disk, never into memory. Package members and producers only;
/// the Portal checks.
enum FootageFile {
    static func path(rowId: String) -> String { "api/package-cycle/a-roll/\(rowId)/download" }

    static func query(_ ids: [String]) -> [URLQueryItem] { ids.map { URLQueryItem(name: "id", value: $0) } }

    /// Only ready clips can be downloaded (or ticked).
    static func readyIDs(_ media: [StageMedia]) -> [String] { media.filter(\.isReady).map(\.id) }

    /// "Download all": a lone ready clip downloads as itself, more as one zip (no ids means all).
    static func allIDs(_ media: [StageMedia]) -> [String] {
        let ready = readyIDs(media)
        return ready.count == 1 ? ready : []
    }

    /// The Portal's (or Drive's) `Content-Disposition` name, else `fallback` with an extension from
    /// the file type; never a path.
    static func filename(suggested: String?, fallback: String, mimeType: String?) -> String {
        let fromServer = clean(suggested ?? "")
        if !fromServer.isEmpty, fromServer != "Unknown", !(fromServer as NSString).pathExtension.isEmpty {
            return fromServer
        }
        let base = clean(fallback).isEmpty ? "Footage" : clean(fallback)
        guard (base as NSString).pathExtension.isEmpty else { return base }
        let ext = mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "mp4"
        return "\(base).\(ext)"
    }

    /// Where finished downloads wait for the share sheet. Emptied when the next one starts, so a
    /// multi-GB zip doesn't linger in the app's storage.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Footage", isDirectory: true)
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        // Time allowed between bytes: the zip waits while the Portal opens each clip on Drive.
        config.timeoutIntervalForRequest = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Streams `request` to a file and returns it under `folder`. `progress` gets the bytes so far
    /// and the total when the server sent one (a zip doesn't). Cancelling the task stops the download.
    static func download(_ request: URLRequest, fallbackName: String, session: URLSession = FootageFile.session,
                         progress: @escaping @MainActor (Int64, Int64?) -> Void) async throws -> URL {
        let tracker = Tracker(portalHost: request.url?.host, report: progress)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request, delegate: tracker)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw PortalError.from(error)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PortalError.from(status: status, message: PortalJSON.errorMessage(errorBody(temporary)))
        }
        let name = filename(suggested: response.suggestedFilename, fallback: fallbackName, mimeType: response.mimeType)
        let destination = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// The start of a refusal's body (the Portal's `{ error: { message } }`), without reading a big file.
    private static func errorBody(_ file: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 64 * 1024)) ?? Data()
    }

    private static func clean(_ value: String) -> String {
        let last = (value as NSString).lastPathComponent
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        return last == "." || last == ".." || last == "/" ? "" : last
    }

    /// Bytes received (watched on the task, a few times a second) and redirects: the Portal's
    /// session cookie stays on the Portal when a single clip redirects to Drive.
    private final class Tracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let portalHost: String?
        private let report: @MainActor (Int64, Int64?) -> Void
        private let lock = NSLock()
        private var observation: NSKeyValueObservation?
        private var lastReport = Date.distantPast

        init(portalHost: String?, report: @escaping @MainActor (Int64, Int64?) -> Void) {
            self.portalHost = portalHost
            self.report = report
        }

        deinit { observation?.invalidate() }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            let observation = task.observe(\.countOfBytesReceived, options: [.new]) { [weak self] task, _ in
                self?.received(task.countOfBytesReceived, expected: task.countOfBytesExpectedToReceive)
            }
            lock.withLock { self.observation = observation }
        }

        private func received(_ bytes: Int64, expected: Int64) {
            let now = Date()
            let due = lock.withLock {
                guard now.timeIntervalSince(lastReport) >= 0.25 else { return false }
                lastReport = now
                return true
            }
            guard due else { return }
            let total = expected > 0 ? expected : nil
            Task { @MainActor [report] in report(bytes, total) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard request.url?.host != portalHost else { return request }
            var next = request
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            return next
        }
    }
}
