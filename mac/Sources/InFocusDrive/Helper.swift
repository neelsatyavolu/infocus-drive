import Foundation

/// Errors from the bundled `infocus` CLI.
enum CLIError: LocalizedError {
    case missingBinary
    case signedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingBinary: return "The app is missing its infocus helper. Reinstall InFocus Drive."
        case .signedOut: return "You're signed out. Sign in again."
        case .failed(let message): return message
        }
    }

    static let exitAuth: Int32 = 3

    /// Turns the CLI's `--json` error line ({"error": …}) into an error.
    static func from(status: Int32, stderr: Data) -> CLIError {
        if status == exitAuth { return .signedOut }
        let lines = String(decoding: stderr, as: UTF8.self).split(separator: "\n")
        for line in lines.reversed() {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let message = obj["error"] as? String {
                return .failed(message.prefix(1).uppercased() + message.dropFirst())
            }
        }
        let text = lines.last.map(String.init) ?? "infocus exited with status \(status)"
        return .failed(text)
    }
}

/// One run of the bundled `infocus` CLI (login, whoami, logout).
final class CLIRun {
    private let process = Process()

    init(_ arguments: [String]) throws {
        guard let binary = Bundle.main.url(forAuxiliaryExecutable: "infocus") else {
            throw CLIError.missingBinary
        }
        process.executableURL = binary
        process.arguments = arguments
    }

    /// Runs to completion and returns stdout; throws CLIError on failure.
    func output() async throws -> Data {
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        }
        try process.run()
        async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
        var status: Int32 = -1
        for await code in exited { status = code }
        let (outData, errData) = await (out, err)
        guard status == 0 else { throw CLIError.from(status: status, stderr: errData) }
        return outData
    }

    func cancel() {
        if process.isRunning { process.interrupt() }
    }
}

/// The `infocus webdav` helper: a loopback WebDAV server for Finder.
@MainActor
final class DavServer {
    enum Event { case exited(Int32), signedOut, upload([String: Any]) }

    private var process: Process?
    private var input: Pipe?
    private var buffer = Data()
    private var ready: CheckedContinuation<URL, Error>?
    private var stderrTail = Data()
    var onEvent: ((Event) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    /// Starts the helper and waits for its "ready" event with the mount URL.
    func start(server: String, port: Int, password: String) async throws -> URL {
        stop()
        guard let binary = Bundle.main.url(forAuxiliaryExecutable: "infocus") else {
            throw CLIError.missingBinary
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--server", server, "webdav", "--addr", "127.0.0.1:\(port)"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            // Ignore a stopped helper's last lines (its upload ids restart at 1).
            Task { @MainActor in
                guard let self, self.process === process else { return }
                self.receive(data)
            }
        }
        let log = HelperLog.open()
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                try? log?.close()
                return
            }
            log?.write(data)
            Task { @MainActor in
                guard let self, self.process === process else { return }
                self.stderrTail = (self.stderrTail + data).suffix(4096)
            }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            // Let the last stderr lines arrive first; they explain the exit.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.exited(proc, status: status)
            }
        }
        self.process = process
        self.input = input
        buffer = Data()
        stderrTail = Data()
        try process.run()
        // The password goes over stdin (never argv); the pipe stays open so
        // the helper exits by itself if this app dies.
        input.fileHandleForWriting.write(Data((password + "\n").utf8))
        return try await withCheckedThrowingContinuation { ready = $0 }
    }

    /// Stops the helper by closing its stdin, which it treats as "app quit".
    func stop() {
        if let ready {
            self.ready = nil
            ready.resume(throwing: CLIError.failed("Stopped."))
        }
        guard let process else { return }
        self.process = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 35) {
            if process.isRunning && process.processIdentifier == pid { process.terminate() }
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch obj["event"] as? String {
            case "ready":
                if let raw = obj["url"] as? String, let url = URL(string: raw) {
                    ready?.resume(returning: url)
                    ready = nil
                }
            case "signed_out":
                onEvent?(.signedOut)
            case "upload":
                onEvent?(.upload(obj))
            default:
                break
            }
        }
    }

    private func exited(_ proc: Process, status: Int32) {
        guard proc === process else { return } // an older helper we already replaced
        if let ready {
            self.ready = nil
            ready.resume(throwing: CLIError.from(status: status, stderr: stderrTail))
        }
        process = nil
        input = nil
        onEvent?(.exited(status))
    }
}

/// Appends helper stderr to ~/Library/Logs/InFocus Drive/helper.log.
enum HelperLog {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/InFocus Drive/helper.log")
    }

    static func open() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }
}
