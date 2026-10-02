import SwiftUI
import UserNotifications

/// UserDefaults key: show the InFocus icon in the menu bar.
let showInMenuBarKey = "showInMenuBar"

@main
struct InFocusDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(showInMenuBarKey) private var showInMenuBar = true

    init() {
        // Writing to a helper that already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        Brand.registerFonts()
        #if DEBUG
        PreviewRenderer.runIfRequested()
        #endif
        // Before any scene (and so the controller) exists.
        AppDelegate.handOffToRunningCopy()
        AppRename.runIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuView(drive: delegate.drive)
        } label: {
            MenuBarIcon(drive: delegate.drive)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    lazy var drive = DriveController()
    /// Another copy asks the running one to show its window through this.
    nonisolated static let showWindowNote = Notification.Name("com.github.neelsatyavolu.infocus-drive.show-window")

    /// Before launch finishes, so a click on a notification that launched the app is delivered.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showWindowNote, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showMainWindow() }
        }
        LoginItem.migrate()
        LoginItem.reRegisterAfterRename()
        _ = drive // start connecting now, whether or not any UI is visible
        drive.updater.start(drive: drive)
        NotificationRouter.shared.drive = drive
        MenuActions.shared.drive = drive
        Task { await PushRegistrar.shared.start() }
        // Start at login passes --background: stay quiet. Opening the app
        // yourself (Finder, Spotlight, Launchpad) shows the window.
        let background = CommandLine.arguments.contains("--background")
        if !background || !drive.hasServer {
            showMainWindow()
        }
    }

    /// Opening the app again while it runs (e.g. from Finder) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep the Finder volume mounted in the background
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        drive.shutdown()
        return .terminateNow
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrar.shared.didRegister(deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushRegistrar.shared.didFail(error)
    }

    /// The Portal window; builds without a Portal address show the Drive window.
    func showMainWindow() {
        if !Windows.shared.showPortal(drive) {
            Windows.shared.showMain(drive)
        }
    }

    /// One copy per account: a second launch asks the running one to show
    /// its window (unless it's a background login launch) and quits.
    nonisolated static func handOffToRunningCopy() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        if !CommandLine.arguments.contains("--background") {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showWindowNote, object: nil, userInfo: nil, deliverImmediately: true)
        }
        // exit, not terminate: this copy must never start its own controller
        // (it would clean up the running copy's volume as "stale").
        exit(0)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var drive: DriveController

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        if drive.transfers.contains(where: { $0.state == .active }) { return "arrow.up.circle" }
        switch drive.summary.1 {
        case .ok: return "externaldrive.fill"
        case .problem: return "externaldrive.badge.exclamationmark"
        default: return "externaldrive"
        }
    }
}
