import Foundation

/// Streams a file (a video from the camera roll can be gigabytes) to an upload
/// URL with progress, without loading it into memory. The Portal's upload
/// routes hand out the destination (InFocus Drive / NAS, see the Portal's
/// docs/NAS-STORAGE.md); the feature that starts an upload asks for it first,
/// then calls this.
///
///     let target = try await client.post("api/package-cycle/upload", body: …, as: UploadTarget.self)
///     try await PortalUpload.file(at: movieURL, to: target.url, headers: target.headers) { progress in … }
enum PortalUpload {
    struct Failed: LocalizedError {
        let status: Int
        var errorDescription: String? { "The upload didn't finish (\(status)). Try again." }
    }

    /// PUT (or POST) the file's bytes. `progress` gets 0…1 on the main actor.
    @discardableResult
    static func file(at fileURL: URL, to destination: URL, method: String = "PUT", headers: [String: String] = [:],
                     session: URLSession = .shared,
                     progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> Data {
        var request = URLRequest(url: destination)
        request.httpMethod = method
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let tracker = ProgressTracker(progress)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: tracker)
        } catch let error as URLError {
            throw PortalError.from(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failed(status: status) }
        await progress(1)
        return data
    }

    private final class ProgressTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let report: @MainActor (Double) -> Void

        init(_ report: @escaping @MainActor (Double) -> Void) {
            self.report = report
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            Task { @MainActor [report] in report(fraction) }
        }
    }
}
