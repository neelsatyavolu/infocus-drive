import ServiceManagement

/// Start at login, in the background: a LaunchAgent in the app bundle
/// (Contents/Library/LaunchAgents) runs the app with `--background`, so it
/// mounts the drive without opening a window. Opening the app yourself shows
/// the window instead.
enum LoginItem {
    static let plistName = "com.github.neelsatyavolu.infocus-drive.login.plist"
    private static var agent: SMAppService { SMAppService.agent(plistName: plistName) }

    static var isEnabled: Bool { agent.status == .enabled }

    static func set(_ on: Bool) throws {
        // Earlier versions registered the app itself (no --background flag).
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        if on {
            try agent.register()
            if agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            try agent.unregister()
        }
    }

    /// Moves a 0.3–0.4 login item (plain "open the app") to the background agent.
    static func migrate() {
        guard SMAppService.mainApp.status == .enabled else { return }
        try? set(true)
    }
}
