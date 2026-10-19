import Foundation
import UniformTypeIdentifiers

/// Slack attachments, downloaded signed in through the Portal's file proxy
/// (`GET api/slack/files/<fileId>`, the link the web feed uses) and opened in Quick Look.
enum SlackFiles {
    /// Slack file ids look like "F01ABC…" (the proxy refuses anything else).
    static func isFileID(_ id: String) -> Bool {
        id.range(of: "^F[A-Z0-9]+$", options: .regularExpression) != nil
    }

    /// The name to save under: the Portal's `Content-Disposition` name, else the post's title with
    /// an extension from the file type (Quick Look needs one), never a path.
    static func filename(suggested: String?, title: String, mimeType: String?) -> String {
        let fromServer = clean(suggested ?? "")
        if !fromServer.isEmpty, fromServer != "Unknown", !(fromServer as NSString).pathExtension.isEmpty {
            return fromServer
        }
        let base = clean(title).isEmpty ? (fromServer.isEmpty ? "Attachment" : fromServer) : clean(title)
        guard (base as NSString).pathExtension.isEmpty,
              let mimeType, let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }

    /// Downloads one attachment to a fresh temporary folder and returns the file.
    static func download(id: String, title: String, client: PortalClient,
                         session: URLSession = PortalClient.urlSession) async throws -> URL {
        guard isFileID(id) else { throw PortalError.notFound }
        var request = await client.request("GET", "api/slack/files/\(id)")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PortalError.from(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = PortalError.from(status: status, message: PortalJSON.errorMessage(data))
            if error == .unauthorized { await AppModel.shared.sessionEnded() }
            throw error
        }
        let name = filename(suggested: response.suggestedFilename, title: title, mimeType: response.mimeType)
        return try save(data, named: name)
    }

    /// Writes bytes under a new folder in tmp (keeps the name as-is for the Quick Look title).
    static func save(_ data: Data, named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlackFiles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func clean(_ value: String) -> String {
        let last = (value as NSString).lastPathComponent
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        return last == "." || last == ".." || last == "/" ? "" : last
    }
}
