import AppKit
import SwiftUI
import WebKit

/// The app's windows (Portal, Drive, Help, Unlock), opened from the menu bar,
/// from a launch or reopen, or from each other. The app runs in the background
/// with no Dock icon; while any of these windows is open it shows in the Dock
/// and the app switcher like a normal app.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()
    private var open: [String: NSWindow] = [:]
    private var portals: [PortalWindowController] = []

    var hasOpenWindows: Bool {
        !open.isEmpty || portals.contains { $0.window?.isVisible == true }
    }

    // MARK: Portal

    /// Shows the frontmost Portal window (making one if needed), optionally at
    /// `url`. False when this build has no Portal address.
    @discardableResult
    func showPortal(_ drive: DriveController, url: URL? = nil) -> Bool {
        guard let portal = AppConfig.shared.portalURL else { return false }
        let controller: PortalWindowController
        if let existing = portals.first(where: { $0.window?.isKeyWindow == true }) ?? portals.last {
            controller = existing
            if let url { existing.web.load(url) }
        } else {
            controller = PortalWindowController(portal: portal, drive: drive, url: url)
            portals.append(controller)
        }
        present(controller.window, drive: drive)
        return true
    }

    /// File → New Window, or a new tab next to `tabbedWith` (Cmd+T).
    func newPortalWindow(_ drive: DriveController, tabbedWith: PortalWindowController?) {
        guard let portal = AppConfig.shared.portalURL else { return }
        let controller = PortalWindowController(portal: portal, drive: drive, url: nil)
        portals.append(controller)
        if let host = tabbedWith?.window, let window = controller.window {
            host.addTabbedWindow(window, ordered: .above)
        }
        present(controller.window, drive: drive)
    }

    /// The last Portal window hides instead of closing, so it reopens instantly.
    func portalShouldClose(_ controller: PortalWindowController) -> Bool {
        guard portals.count == 1, portals.first === controller else { return true }
        controller.window?.orderOut(nil)
        backgroundIfIdle()
        return false
    }

    func portalClosed(_ controller: PortalWindowController) {
        portals.removeAll { $0 === controller }
        backgroundIfIdle()
    }

    /// After signing in or out: other Portal windows pick up the new session.
    func reloadPortals(except webView: WKWebView?) {
        for controller in portals where controller.web.webView !== webView {
            controller.web.webView.reload()
        }
    }

    private func present(_ window: NSWindow?, drive: DriveController) {
        MainMenu.install()
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func backgroundIfIdle() {
        if !hasOpenWindows {
            // Back to running quietly in the background (menu bar icon optional).
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Drive windows

    func showMain(_ drive: DriveController) {
        show("main", title: "Drive") { MainWindowView(drive: drive) }
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
        MainMenu.install()
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
        backgroundIfIdle()
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
