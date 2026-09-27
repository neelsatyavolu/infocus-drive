import SwiftUI

@main
struct InFocusDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Brand.registerFonts()
        #if DEBUG
        PreviewRenderer.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(drive: delegate.drive)
        } label: {
            MenuBarIcon(drive: delegate.drive)
        }
        .menuBarExtraStyle(.window)

        Window("InFocus Drive Help", id: "help") {
            HelpView(drive: delegate.drive)
        }
        .windowResizability(.contentSize)
    }
}

/// MenuView plus the environment it needs to open the Help window.
private struct MenuContent: View {
    @ObservedObject var drive: DriveController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuView(drive: drive) {
            openWindow(id: "help")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    lazy var drive = DriveController()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        drive.shutdown()
        return .terminateNow
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
