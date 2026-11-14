import AppKit
import Combine

/// Mac backup (for the Drive usernames in AppConfig.backupUserHashes): copies a
/// folder on this Mac to a Drive folder every hour with `infocus backup`. The
/// CLI remembers what it sent, so a run where little changed only walks the
/// local folder. Files deleted here are moved to the share's Recycle bin once
/// they've stayed deleted for a week.
@MainActor
final class BackupController: ObservableObject {
    struct Settings: Codable, Equatable {
        var source: String     // absolute local folder
        var shareID: String    // --share
        var shareName: String  // folder name at the volume root, for display
        var remotePath: String // inside the share; "" = share root
        var automatic = true
    }

    enum Phase: String { case scanning, checking, uploading, deleting }

    struct Progress: Equatable {
        var filesDone = 0, filesTotal = 0
        var bytesDone: Int64 = 0, bytesTotal: Int64 = 0
        var current = ""

        var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
    }

    struct Outcome: Codable, Equatable {
        var finishedAt: Date
        var uploaded = 0
        var bytes: Int64 = 0
        var unchanged = 0
        var deleted = 0
        var pendingDelete = 0
        var failed = 0
        var conflicts = 0
        var noRecycleBin = false
        var error: String?
    }

    nonisolated static let interval: TimeInterval = 60 * 60
    /// A full check against the Drive (catches files removed there) once a day.
    static let verifyInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let deleteAfter = "168h"

    @Published private(set) var settings: Settings?
    @Published private(set) var lastOutcome: Outcome?
    @Published private(set) var isRunning = false
    @Published private(set) var phase: Phase?
    @Published private(set) var progress = Progress()

    private weak var drive: DriveController?
    private var timer: Timer?
    private var process: Process?
    private var cancelled = false
    private var forward: AnyCancellable?
    private let defaults = UserDefaults.standard
    private var lastAttempt: Date? {
        get { defaults.object(forKey: "backupLastAttempt") as? Date }
        set { defaults.set(newValue, forKey: "backupLastAttempt") }
    }
    private var lastVerify: Date? {
        get { defaults.object(forKey: "backupLastVerify") as? Date }
        set { defaults.set(newValue, forKey: "backupLastVerify") }
    }

    init() {
        settings = Self.load(Settings.self, key: "backupSettings")
        lastOutcome = Self.load(Outcome.self, key: "backupLastOutcome")
    }

    func start(drive: DriveController) {
        self.drive = drive
        // The menu-bar icon and sections observe the drive controller.
        forward = objectWillChange.sink { [weak drive] _ in drive?.objectWillChange.send() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runIfDue() }
        }
    }

    // MARK: Running

    /// Hourly (checked every minute, so it also catches up after sleep).
    func runIfDue(now: Date = Date()) {
        guard isConfigured, let settings, settings.automatic, available, drive?.status.online != false else { return }
        if Self.isDue(lastAttempt: lastAttempt, now: now) { runNow() }
    }

    nonisolated static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval || now < lastAttempt
    }

    var available: Bool { drive?.backupAvailable == true }

    func runNow() {
        // Both folders must be chosen: never a half-set-up backup.
        guard !isRunning, isConfigured, let settings, let drive, available,
              let binary = Bundle.main.url(forAuxiliaryExecutable: "infocus") else { return }
        let now = Date()
        lastAttempt = now
        let verify = lastVerify.map { now.timeIntervalSince($0) >= Self.verifyInterval } ?? true
        let process = Process()
        process.executableURL = binary
        process.arguments = Self.arguments(settings: settings, server: drive.serverURL, stateFile: Self.stateFile.path,
                                           verify: verify, home: FileManager.default.homeDirectoryForCurrentUser.path)
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let lines = LineBuffer()
        // Read stdout as it comes: a big result must not fill the pipe and stall the CLI.
        let result = DataBox()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; result.close(); return }
            result.append(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let complete = lines.append(data)
            Task { @MainActor in complete.forEach { self?.event($0) } }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                // Let the last reads arrive (they come on the pipes' own queue).
                for _ in 0..<50 where !result.isClosed {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // stderr's last lines
                self?.finished(status: status, stdout: result.data, stderrTail: lines.tail, verified: verify)
            }
        }
        do {
            try process.run()
        } catch {
            record(Outcome(finishedAt: Date(), error: "Couldn't start the backup: \(error.localizedDescription)"))
            return
        }
        self.process = process
        isRunning = true
        phase = .scanning
        progress = Progress()
    }

    func cancel() {
        if let process, process.isRunning {
            cancelled = true
            process.interrupt()
        }
    }

    private func event(_ line: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        switch obj["event"] as? String {
        case "phase":
            phase = (obj["phase"] as? String).flatMap(Phase.init(rawValue:))
        case "progress":
            progress = Progress(
                filesDone: obj["files_done"] as? Int ?? 0, filesTotal: obj["files_total"] as? Int ?? 0,
                bytesDone: (obj["bytes_done"] as? NSNumber)?.int64Value ?? 0,
                bytesTotal: (obj["bytes_total"] as? NSNumber)?.int64Value ?? 0,
                current: obj["current"] as? String ?? "")
        default:
            break
        }
    }

    private func finished(status: Int32, stdout: Data, stderrTail: String, verified: Bool) {
        process = nil
        isRunning = false
        phase = nil
        let stopped = cancelled
        cancelled = false
        // A result on stdout covers partial runs too (some files failed).
        var outcome = Self.outcome(stdout: stdout, at: Date())
            ?? Outcome(finishedAt: Date(), error: CLIError.from(status: status, stderr: Data(stderrTail.utf8)).localizedDescription)
        if stopped { outcome.error = "Stopped before it finished. The next backup picks up from here." }
        if status == 0 && verified { lastVerify = Date() }
        record(outcome)
        if status == CLIError.exitAuth { Task { await drive?.refreshAccount() } }
        if drive?.isTransferring == false { drive?.updater.transfersIdle() }
    }

    private func record(_ outcome: Outcome) {
        lastOutcome = outcome
        Self.save(outcome, key: "backupLastOutcome")
    }

    // MARK: Settings

    /// Pick the Mac folder to back up.
    func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Back Up This Folder"
        panel.message = "Choose a folder to back up. Your home folder backs up everything you keep on this Mac."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = Self.sourceProblem(url.path, volume: drive?.connectedVolume?.path) {
            drive?.showMessage(problem)
            return
        }
        update { $0.source = url.standardizedFileURL.path }
    }

    /// Pick where on the Drive it goes, in the mounted volume.
    func chooseDestination() {
        guard let drive, let volume = drive.connectedVolume else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Back Up Here"
        panel.message = "Choose a folder on InFocus Drive for the backup (New Folder makes one)."
        panel.directoryURL = volume
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let (shareName, remote) = Self.destination(url.standardizedFileURL.path, volume: volume.standardizedFileURL.path),
              let share = drive.status.shares.first(where: { $0.name == shareName }) else {
            drive.showMessage("Choose a folder inside one of your shares on InFocus Drive.")
            return
        }
        guard share.canWrite else {
            drive.showMessage("\(share.name) is read-only for you. Choose a share you can save to.")
            return
        }
        update {
            $0.shareID = share.id
            $0.shareName = share.name
            $0.remotePath = remote
        }
    }

    func setAutomatic(_ on: Bool) {
        update { $0.automatic = on }
    }

    /// Changes the settings; a new folder pair starts a fresh backup state.
    private func update(_ change: (inout Settings) -> Void) {
        var next = settings ?? Settings(source: "", shareID: "", shareName: "", remotePath: "")
        change(&next)
        settings = next
        Self.save(next, key: "backupSettings")
    }

    var isConfigured: Bool {
        guard let settings else { return false }
        return settings.source.hasPrefix("/") && settings.source != "/" && !settings.shareID.isEmpty
    }

    var diagnostics: String {
        guard let settings, isConfigured else { return "not set up" }
        let last = lastOutcome.map { o in
            "last \(Formatting.time(o.finishedAt)): \(o.uploaded) uploaded, \(o.failed) failed" + (o.error.map { " — \($0)" } ?? "")
        } ?? "never run"
        return "\(settings.automatic ? "hourly" : "manual"), \(last)"
    }

    #if DEBUG
    /// PreviewRenderer: show the section with this state.
    private(set) var previewShown: Bool?

    func preview(settings: Settings?, outcome: Outcome?, running: Phase? = nil, progress: Progress = Progress()) {
        previewShown = true
        self.settings = settings
        lastOutcome = outcome
        isRunning = running != nil
        phase = running
        self.progress = progress
    }
    #endif

    // MARK: Pure helpers (tested)

    nonisolated static var stateFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/InFocus/backup-state.json")
    }

    nonisolated static func arguments(settings: Settings, server: String, stateFile: String, verify: Bool, home: String) -> [String] {
        var args = ["--json", "--server", server, "--share", settings.shareID,
                    "backup", settings.source, settings.remotePath.isEmpty ? "/" : settings.remotePath,
                    "--state", stateFile, "--delete-after", deleteAfter, "--progress"]
        for rel in excludes(source: settings.source, home: home) { args += ["--exclude", rel] }
        if verify { args.append("--verify") }
        return args
    }

    /// Backing up the home folder leaves out app data, caches and the Trash
    /// (big, constantly changing, and not something to restore by hand).
    nonisolated static func excludes(source: String, home: String) -> [String] {
        let clean = { (p: String) in p.hasSuffix("/") ? String(p.dropLast()) : p }
        return clean(source) == clean(home) ? ["Library", ".Trash", ".cache", ".npm", ".Spotlight-V100"] : [".Trash"]
    }

    /// Why a folder can't be the backup source, or nil.
    nonisolated static func sourceProblem(_ path: String, volume: String?) -> String? {
        if path == "/" { return "Choose your home folder or a folder in it, not the whole disk." }
        if path.hasPrefix("/Volumes/"), let volume, path == volume || path.hasPrefix(volume + "/") {
            return "That folder is already on InFocus Drive."
        }
        return nil
    }

    /// A folder in the mounted volume → (share folder name, path inside the share).
    nonisolated static func destination(_ path: String, volume: String) -> (String, String)? {
        guard path.hasPrefix(volume + "/") else { return nil }
        let parts = path.dropFirst(volume.count + 1).split(separator: "/").map(String.init)
        guard let share = parts.first else { return nil }
        return (share, parts.dropFirst().joined(separator: "/"))
    }

    nonisolated static func outcome(stdout: Data, at date: Date) -> Outcome? {
        guard let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else { return nil }
        let list = { (key: String) in (obj[key] as? [Any])?.count ?? 0 }
        return Outcome(finishedAt: date, uploaded: obj["uploaded"] as? Int ?? 0,
                       bytes: (obj["bytes"] as? NSNumber)?.int64Value ?? 0,
                       unchanged: obj["unchanged"] as? Int ?? 0, deleted: list("deleted"),
                       pendingDelete: obj["pending_delete"] as? Int ?? 0,
                       failed: list("failed"), conflicts: list("conflicts"),
                       noRecycleBin: obj["no_recycle_bin"] as? Bool ?? false)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Bytes collected from a pipe handler (thread-safe).
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    private var closed = false

    func append(_ data: Data) {
        lock.lock()
        stored.append(data)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Splits a byte stream into lines across reads (thread-safe; used from the
/// pipe's handler queue). Keeps the last few lines for error messages.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var recent: [String] = []

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        recent = Array((recent + lines.filter { !$0.contains("\"event\"") }).suffix(5))
        return lines
    }

    var tail: String {
        lock.lock()
        defer { lock.unlock() }
        return recent.joined(separator: "\n")
    }
}

extension DriveController {
    /// Mac backup is switched on for the signed-in account in this build.
    var backupAvailable: Bool {
        #if DEBUG
        if let shown = backup.previewShown { return shown }
        #endif
        if case .signedIn(let user) = account { return AppConfig.shared.backupEnabled(for: user) }
        return false
    }
}
