import AppKit
import Network
import ServiceManagement

/// Signs in, runs the WebDAV helper and keeps the Finder volume mounted.
@MainActor
final class DriveController: ObservableObject {
    enum Account: Equatable { case unknown, signedOut, signingIn, signedIn(String) }
    enum Connection: Equatable { case disconnected, connecting, connected(URL), failed(String) }

    static let volumeName = "InFocus Drive"
    private static let davUser = "infocus"

    @Published private(set) var serverURL: String
    @Published private(set) var account: Account = .unknown
    @Published private(set) var connection: Connection = .disconnected
    @Published private(set) var message: String?
    @Published private(set) var startsAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var status = DriveStatus()
    @Published private(set) var transfers: [Transfer] = []
    /// The encrypted personal folder the Unlock window is working on.
    @Published private(set) var unlocking: PersonalUnlock?

    private let defaults = UserDefaults.standard
    private let dav = DavServer()
    /// Secret between this app, the helper and NetFS; new for every helper
    /// start, so nothing that talked to an earlier helper can reuse it.
    private var davPassword = ""
    private var mountURL: URL?
    private var loginRun: CLIRun?
    private var working = false
    private var checking = false
    private var restartDelay: UInt64 = 1
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?

    private var wantsConnected: Bool {
        get { defaults.bool(forKey: "wantsConnected") }
        set { defaults.set(newValue, forKey: "wantsConnected") }
    }

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        dav.onEvent = { [weak self] event in self?.helperEvent(event) }
        observeSystem()
        Task { await start() }
    }

    #if DEBUG
    /// Inert controller for PreviewRenderer: no helper, observers or timers.
    init(previewServer: String) {
        serverURL = previewServer
    }

    func applyPreview(account: Account, connection: Connection, status: DriveStatus, transfers: [Transfer]) {
        self.account = account
        self.connection = connection
        self.status = status
        self.transfers = transfers
    }
    #endif

    // MARK: Setup and account

    var hasServer: Bool { !serverURL.isEmpty }

    var serverHost: String { URL(string: serverURL)?.host ?? serverURL }

    /// Validates and saves the Drive address (https, no path).
    func setServer(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var parts = URLComponents(string: candidate), let host = parts.host, !host.isEmpty,
              parts.scheme == "https" || (parts.scheme == "http" && host == "localhost"),
              parts.query == nil, ["", "/"].contains(parts.path) else {
            message = "Enter your Drive address, like https://drive.example.com"
            return
        }
        parts.path = ""
        serverURL = parts.string ?? candidate
        defaults.set(serverURL, forKey: "serverURL")
        message = nil
        Task { await refreshAccount() }
    }

    func changeServer() {
        disconnect()
        serverURL = ""
        defaults.removeObject(forKey: "serverURL")
        account = .unknown
    }

    private func start() async {
        guard hasServer else { return }
        cleanUpStaleVolumes()
        await refreshAccount()
        if wantsConnected { await ensureConnected() }
    }

    /// Checks the sign-in and how the Drive responds (also fills the status
    /// dashboard: email, shares, latency).
    func refreshAccount() async {
        guard hasServer, account != .signingIn, !checking else { return }
        checking = true
        defer { checking = false }
        let started = Date()
        var next = status
        next.checkedAt = Date()
        do {
            let out = try await CLIRun(["--json", "--server", serverURL, "whoami"]).output()
            let info = DriveStatus.account(fromWhoami: out)
            account = .signedIn(info.username)
            next.email = info.email
            next.shares = info.shares
            next.driveReachable = true
            next.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            if message == CLIError.signedOut.errorDescription { message = nil }
        } catch CLIError.signedOut {
            account = .signedOut
            next.driveReachable = true
        } catch {
            // Offline or the Drive is down: keep what we knew, retry later.
            next.driveReachable = false
            next.latencyMs = nil
            if account == .unknown { message = error.localizedDescription }
        }
        status = next
    }

    /// Re-checks the Drive if the last check is older than maxAge.
    func refreshIfStale(maxAge: TimeInterval = 20) {
        if let checked = status.checkedAt, Date().timeIntervalSince(checked) < maxAge { return }
        Task { await refreshAccount() }
    }

    func signIn() {
        guard hasServer else { return }
        let device = (Host.current().localizedName ?? "Mac") + " (Finder)"
        do {
            let run = try CLIRun(["--json", "--server", serverURL, "login", "--device", device])
            loginRun = run
            account = .signingIn
            message = nil
            Task {
                defer { loginRun = nil }
                do {
                    let out = try await run.output()
                    let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any]
                    account = .signedIn(obj?["username"] as? String ?? "")
                    connect()
                } catch {
                    account = .signedOut
                    message = error.localizedDescription
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func cancelSignIn() {
        loginRun?.cancel()
    }

    func signOut() {
        disconnect()
        Task {
            _ = try? await CLIRun(["--json", "--server", serverURL, "logout"]).output()
            account = .signedOut
        }
    }

    // MARK: Connection

    func connect() {
        wantsConnected = true
        message = nil
        Task { await ensureConnected(openFinder: true) }
    }

    func disconnect() {
        wantsConnected = false
        if let volume = connectedVolume {
            // Clear the state first: the unmount notification arrives later
            // and must not look like a Finder eject.
            connection = .disconnected
            do {
                try Mounter.unmount(volume, force: false)
            } catch {
                wantsConnected = true
                connection = .connected(volume)
                message = "Close files that are open on \(Self.volumeName), then try again."
                return
            }
        }
        stopHelper()
        connection = .disconnected
    }

    func openInFinder() {
        if let volume = connectedVolume { NSWorkspace.shared.open(volume) }
    }

    func openShare(_ share: DriveStatus.Share) {
        guard let volume = connectedVolume else { return }
        NSWorkspace.shared.open(volume.appendingPathComponent(share.name, isDirectory: true))
    }

    /// Starts unlocking an encrypted personal folder (shown in the Unlock window).
    func beginUnlock(_ share: DriveStatus.Share) {
        // Fresh each time (never a half-finished step), unless one is running.
        if unlocking?.busy != true {
            unlocking = PersonalUnlock(share: share, drive: self)
        }
    }

    /// After an unlock: refresh the shares and open the folder in Finder.
    func personalFolderUnlocked(_ share: DriveStatus.Share) async {
        await refreshAccount()
        if let fresh = status.shares.first(where: { $0.id == share.id }), !fresh.locked {
            openShare(fresh)
        }
    }

    func openDriveWebsite() {
        if let url = URL(string: serverURL) { NSWorkspace.shared.open(url) }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private var connectionText: String {
        switch connection {
        case .connected(let volume): return "mounted at \(volume.path)"
        case .connecting: return "connecting"
        case .disconnected: return wantsConnected ? "not connected (will retry)" : "disconnected"
        case .failed(let reason): return "failed — \(reason)"
        }
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(), forType: .string)
    }

    /// A plain-text summary for support. No tokens or passwords.
    func diagnostics() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let who: String
        switch account {
        case .signedIn(let user): who = "signed in as \(user)"
        case .signedOut: who = "signed out"
        case .signingIn: who = "signing in"
        case .unknown: who = "unknown"
        }
        let drive: String
        switch status.driveReachable {
        case true?: drive = "reachable" + (status.latencyMs.map { " (\($0) ms)" } ?? "")
        case false?: drive = "unreachable"
        case nil: drive = "not checked"
        }
        let lines = [
            "InFocus Drive for Mac \(Self.appVersion) on macOS \(os)",
            "Drive: \(serverHost) — \(drive)",
            "Account: \(who)",
            "Connection: " + connectionText,
            "Helper: " + (status.helperSince.map { "running since \(Formatting.time($0))" } ?? "stopped")
                + " (restarts: \(status.helperRestarts))",
            "Network: " + (status.online ? "online \(status.networkKind)" : "offline"),
            "Shares: \(status.shares.count)",
            "Transfers: " + transfers.map { "\($0.name) \($0.state.rawValue)\($0.error.isEmpty ? "" : ": " + $0.error)" }
                .joined(separator: "; "),
            "Last message: \(message ?? "none")",
        ]
        return lines.joined(separator: "\n")
    }

    var connectedVolume: URL? {
        if case .connected(let volume) = connection { return volume }
        return nil
    }

    /// Makes sure the helper runs and the volume is mounted. Safe to call
    /// often: on launch, wake, network changes and a timer.
    func ensureConnected(openFinder: Bool = false) async {
        guard wantsConnected, hasServer, !working else { return }
        switch account {
        case .signedOut, .signingIn: return
        default: break
        }
        working = true
        defer { working = false }
        if connectedVolume == nil { connection = .connecting }
        do {
            let url = try await runningHelper()
            let volume = try await mountedVolume(for: url)
            guard wantsConnected else {
                // Disconnect was clicked while the mount was in progress.
                try? Mounter.unmount(volume, force: true)
                return
            }
            connection = .connected(volume)
            message = nil
            if openFinder { NSWorkspace.shared.open(volume) }
        } catch CLIError.signedOut {
            handleSignedOut()
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    private func runningHelper() async throws -> URL {
        if dav.isRunning, let mountURL { return mountURL }
        // A volume still pointing at an old helper's port must go before a
        // new helper starts: another account could take that port over.
        cleanUpStaleVolumes()
        davPassword = Self.randomPassword()
        let url = try await dav.start(server: serverURL, port: 0, password: davPassword)
        mountURL = url
        restartDelay = 1
        status.helperSince = Date()
        return url
    }

    private func mountedVolume(for url: URL) async throws -> URL {
        let ours = Mounter.helperVolumes(path: "/" + Self.volumeName)
        if let current = ours.first(where: { $0.source.port == url.port }) {
            return current.volume
        }
        connection = .connecting
        cleanUpStaleVolumes()
        return try await Mounter.mount(url, user: Self.davUser, password: davPassword)
    }

    /// Unmounts volumes left by a helper that no longer runs (e.g. a crash).
    private func cleanUpStaleVolumes() {
        let live = dav.isRunning ? mountURL?.port : nil
        for stale in Mounter.helperVolumes(path: "/" + Self.volumeName) where stale.source.port != live {
            try? Mounter.unmount(stale.volume, force: true)
        }
    }

    private func handleSignedOut() {
        let volume = connectedVolume
        connection = .disconnected
        if let volume { try? Mounter.unmount(volume, force: true) }
        stopHelper()
        account = .signedOut
        message = CLIError.signedOut.errorDescription
    }

    /// Stops the helper; uploads it hadn't finished didn't reach the Drive.
    private func stopHelper() {
        dav.stop()
        helperStopped()
    }

    private func helperStopped() {
        status.helperSince = nil
        transfers = transfers.map { transfer in
            guard transfer.state == .active else { return transfer }
            var interrupted = transfer
            interrupted.state = .failed
            interrupted.error = "Interrupted when the connection stopped. Copy the file again."
            interrupted.updatedAt = Date()
            return interrupted
        }
    }

    private func helperEvent(_ event: DavServer.Event) {
        switch event {
        case .upload(let raw):
            if let transfer = Transfer(event: raw, now: Date()) {
                transfers = mergeTransfer(transfer, into: transfers, now: Date())
            }
        case .signedOut, .exited(CLIError.exitAuth):
            helperStopped()
            handleSignedOut()
        case .exited:
            helperStopped()
            status.helperRestarts += 1
            // Crashed: drop the volume now (nothing may keep talking to a
            // port that is free again), then start a new helper and remount.
            if let volume = connectedVolume {
                connection = .connecting
                try? Mounter.unmount(volume, force: true)
            }
            guard wantsConnected else { return }
            let delay = restartDelay
            restartDelay = min(restartDelay * 2, 30)
            Task {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                await ensureConnected()
            }
        }
    }

    /// Quit: unmount first so Finder doesn't keep a dead volume.
    func shutdown() {
        if let volume = connectedVolume {
            connection = .disconnected
            if (try? Mounter.unmount(volume, force: false)) == nil {
                try? Mounter.unmount(volume, force: true)
            }
        }
        stopHelper()
    }

    // MARK: Start at login

    func setStartsAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change Start at login: \(error.localizedDescription)"
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: System events

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.refreshAccount()
                await self?.ensureConnected()
            }
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            Task { @MainActor in self?.volumeUnmounted(path: path) }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let kind = path.usesInterfaceType(.wifi) ? "Wi-Fi"
                : path.usesInterfaceType(.wiredEthernet) ? "Ethernet"
                : path.usesInterfaceType(.cellular) ? "Cellular" : "Online"
            Task { @MainActor in
                guard let self else { return }
                let cameBack = online && !self.status.online
                self.status.online = online
                self.status.networkKind = online ? kind : ""
                guard online else { return }
                if cameBack || self.account == .unknown { await self.refreshAccount() }
                await self.ensureConnected()
            }
        }
        pathMonitor.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.transfers = pruneTransfers(self.transfers, now: Date())
                self.refreshIfStale(maxAge: 120)
                await self.ensureConnected()
            }
        }
    }

    /// Ejecting the volume in Finder means "disconnect"; the helper is stopped
    /// and it isn't remounted until Connect is clicked again.
    private func volumeUnmounted(path: String?) {
        guard let volume = connectedVolume, volume.path == path else { return }
        connection = .disconnected
        if dav.isRunning {
            wantsConnected = false
            stopHelper()
        }
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
