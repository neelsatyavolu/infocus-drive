import AppKit

/// Earlier versions installed "InFocus Drive.app"; the app is now InFocus.
/// Updates keep shipping "InFocus Drive.app" inside InFocus-Drive-mac.zip (the
/// updater in older copies looks for that name), so the first launch from an
/// Applications folder renames the bundle and relaunches from the new path,
/// before anything is mounted. If the rename can't happen, it stays put.
enum AppRename {
    static let oldName = "InFocus Drive.app"
    static let newName = "InFocus.app"
    /// Set before moving when Start at login was on; the relaunched copy re-registers it.
    static let reRegisterLoginKey = "reRegisterLoginItem"

    /// Where the bundle should move, or nil to leave it.
    static func target(for bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard bundle.lastPathComponent == oldName else { return nil }
        let folder = bundle.deletingLastPathComponent()
        let allowed = ["/Applications", home.appendingPathComponent("Applications").standardizedFileURL.path]
        guard allowed.contains(folder.standardizedFileURL.path) else { return nil }
        return folder.appendingPathComponent(newName)
    }

    /// Returns normally unless the app moved (then it relaunches and exits).
    static func runIfNeeded() {
        let bundle = Bundle.main.bundleURL
        guard let target = target(for: bundle), !FileManager.default.fileExists(atPath: target.path) else { return }
        let loginWasOn = LoginItem.isEnabled
        do {
            try FileManager.default.moveItem(at: bundle, to: target)
        } catch {
            NSLog("InFocus: keeping %@ (rename failed: %@)", bundle.path, error.localizedDescription)
            return
        }
        if loginWasOn { UserDefaults.standard.set(true, forKey: reRegisterLoginKey) }
        Updater.relaunch(target, showWindow: !CommandLine.arguments.contains("--background"))
        exit(0) // nothing is running yet: no controller, no mount
    }
}
