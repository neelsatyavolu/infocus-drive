import Foundation

/// Uploads a file to InFocus Drive the way the website does (Portal
/// `src/lib/nas-upload-client.ts`): small files in one multipart POST, larger
/// ones in retried 16 MiB chunks over three streams, so a dropped connection
/// costs one chunk instead of the whole video. Reads chunks from disk; a
/// multi-gigabyte camera file never sits in memory.
enum DriveUploader {
    static let chunkThreshold = 8 * 1024 * 1024
    static let chunkSize = 16 * 1024 * 1024
    static let streams = 3
    static let retries = 3

    struct Failed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ChunkSession: Decodable {
        let upload_id: String?
        let chunk_size: Int?
        let total_chunks: Int?
        let received: [Int]?
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30 * 60
        return URLSession(configuration: config)
    }()

    /// `…/upload` → `…/upload/<leaf>?query`.
    static func serviceURL(_ uploadURL: URL, _ leaf: String, _ query: [String: String] = [:]) -> URL {
        var parts = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)!
        var path = parts.path
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/upload") { path += "/\(leaf)" }
        parts.path = path
        if !query.isEmpty {
            parts.queryItems = (parts.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return parts.url!
    }

    static func upload(file: URL, to drive: DriveUploadSession,
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let path = drive.path, let token = drive.token else {
            throw Failed(message: "InFocus Drive didn't start the upload. Try again.")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw Failed(message: "That file is empty.") }
        if size < chunkThreshold {
            try await simple(file: file, path: path, token: token, url: drive.uploadUrl)
        } else {
            try await chunked(file: file, size: size, path: path, token: token, url: drive.uploadUrl, progress: progress)
        }
        await progress(1)
    }

    // MARK: Small files

    private static func simple(file: URL, path: String, token: String, url: URL) async throws {
        let boundary = "InFocus-\(UUID().uuidString)"
        var body = Multipart.fields(["path": path, "token": token], boundary: boundary, closing: false)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        try await retrying(2) {
            _ = try await send("POST", url, body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        }
    }

    // MARK: Chunks

    private static func chunked(file: URL, size: Int, path: String, token: String, url: URL,
                                progress: @escaping @MainActor (Double) -> Void) async throws {
        let initBoundary = "InFocus-\(UUID().uuidString)"
        let initBody = Multipart.fields(["path": path, "token": token, "name": file.lastPathComponent,
                                         "size": String(size), "chunk_size": String(chunkSize)], boundary: initBoundary)
        let started = try await send("POST", serviceURL(url, "init"), body: initBody,
                                     contentType: "multipart/form-data; boundary=\(initBoundary)")
        let chunkInfo = try? JSONDecoder().decode(ChunkSession.self, from: started)
        guard let uploadId = chunkInfo?.upload_id, let total = chunkInfo?.total_chunks, total > 0 else {
            throw Failed(message: "InFocus Drive couldn't start a chunked upload.")
        }
        let pieceSize = chunkInfo?.chunk_size ?? chunkSize
        let done = Set(chunkInfo?.received ?? [])
        let tally = ByteTally(total: size, progress: progress)
        await tally.add(done.reduce(0) { $0 + pieceLength(index: $1, pieceSize: pieceSize, total: total, size: size) })

        let pending = (0..<total).filter { !done.contains($0) }
        let queue = ChunkQueue(pending)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<min(streams, max(1, pending.count)) {
                group.addTask {
                    while let index = await queue.next() {
                        let length = pieceLength(index: index, pieceSize: pieceSize, total: total, size: size)
                        let data = try read(file, offset: index * pieceSize, length: length)
                        try await retrying(retries) {
                            _ = try await send("PUT", serviceURL(url, "chunk", ["upload_id": uploadId, "index": String(index), "token": token]),
                                               body: data, contentType: "application/octet-stream")
                        }
                        await tally.add(length)
                    }
                }
            }
            try await group.waitForAll()
        }

        let completeBoundary = "InFocus-\(UUID().uuidString)"
        _ = try await send("POST", serviceURL(url, "complete"),
                           body: Multipart.fields(["upload_id": uploadId, "token": token], boundary: completeBoundary),
                           contentType: "multipart/form-data; boundary=\(completeBoundary)")
    }

    static func pieceLength(index: Int, pieceSize: Int, total: Int, size: Int) -> Int {
        index == total - 1 ? max(0, size - pieceSize * (total - 1)) : pieceSize
    }

    private static func read(_ file: URL, offset: Int, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }

    // MARK: Plumbing

    private static func send(_ method: String, _ url: URL, body: Data, contentType: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch let error as URLError {
            throw PortalError.from(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw Failed(message: detail ?? "InFocus Drive didn't accept the upload (\(status)). Try again.")
        }
        return data
    }

    private static func retrying(_ attempts: Int, _ work: () async throws -> Void) async throws {
        var lastError: Error?
        for attempt in 1...attempts {
            do { return try await work() } catch {
                lastError = error
                if attempt < attempts { try await Task.sleep(nanoseconds: UInt64(400_000_000 * attempt)) }
            }
        }
        throw lastError ?? Failed(message: "The upload didn't finish. Try again.")
    }
}

/// Multipart form bodies of plain text fields.
enum Multipart {
    static func fields(_ fields: [String: String], boundary: String, closing: Bool = true) -> Data {
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if closing { body.append(Data("--\(boundary)--\r\n".utf8)) }
        return body
    }
}

/// Hands out chunk indexes to the upload streams.
private actor ChunkQueue {
    private var pending: [Int]
    init(_ pending: [Int]) { self.pending = pending }
    func next() -> Int? { pending.isEmpty ? nil : pending.removeFirst() }
}

/// Bytes sent so far, reported as 0…1.
private actor ByteTally {
    private let total: Int
    private var sent = 0
    private let progress: @MainActor (Double) -> Void

    init(total: Int, progress: @escaping @MainActor (Double) -> Void) {
        self.total = total
        self.progress = progress
    }

    func add(_ bytes: Int) async {
        sent += bytes
        let fraction = min(1, Double(sent) / Double(max(total, 1)))
        await progress(fraction * 0.99)
    }
}
