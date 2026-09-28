import AppKit
import SwiftUI

/// The app's windows (main, Help, Unlock), opened from the menu bar, from a
/// launch or reopen, or from each other. The app runs in the background with no
/// Dock icon; while any of these windows is open it shows in the Dock and the
/// app switcher like a normal app.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    private var open: [String: NSWindow] = [:]

    func showMain(_ drive: DriveController) {
        show("main", title: "InFocus Drive") { MainWindowView(drive: drive) }
    }

    func showHelp(_ drive: DriveController) {
        show("help", title: "InFocus Drive Help") { HelpView(drive: drive) }
    }

    func showUnlock(_ drive: DriveController, share: DriveStatus.Share) {
        drive.beginUnlock(share)
        show("unlock", title: "Unlock Personal Folder") { UnlockView(drive: drive) }
    }

    func close(_ id: String) {
        open[id]?.close()
    }

    private func show<V: View>(_ id: String, title: String, @ViewBuilder content: () -> V) {
        let window = open[id] ?? makeWindow(id: id, title: title, root: content())
        open[id] = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow<V: View>(id: String, title: String, root: V) -> NSWindow {
        let controller = NSHostingController(rootView: root.environment(\.closeWindow, CloseWindowAction { [weak self] in
            self?.close(id)
        }))
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        open[id] = nil
        if open.isEmpty {
            // Back to running quietly in the background (menu bar icon optional).
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Lets a view close the window it lives in.
struct CloseWindowAction {
    let run: () -> Void
    func callAsFunction() { run() }
}

private struct CloseWindowKey: EnvironmentKey {
    static let defaultValue = CloseWindowAction {}
}

extension EnvironmentValues {
    var closeWindow: CloseWindowAction {
        get { self[CloseWindowKey.self] }
        set { self[CloseWindowKey.self] = newValue }
    }
}
