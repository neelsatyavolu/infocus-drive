import AppKit

/// The menu bar while a window is open. Built in AppKit because the app has no
/// SwiftUI window scene, and a web view needs a real Edit menu for Copy/Paste
/// shortcuts. Portal items go up the responder chain to the key Portal window
/// (PortalWindowController), so they're disabled in the Drive window.
@MainActor
enum MainMenu {
    static let identifier = NSUserInterfaceItemIdentifier("InFocusMainMenu")

    /// Installs the menu unless it's already the current one.
    static func install() {
        guard NSApp.mainMenu?.identifier != identifier else { return }
        let menu = NSMenu()
        menu.identifier = identifier
        [appMenu(), fileMenu(), editMenu(), viewMenu(), historyMenu(), windowMenu(), helpMenu()]
            .forEach { submenu in
                let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                menu.addItem(item)
            }
        NSApp.mainMenu = menu
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "InFocus")
        menu.addItem(withTitle: "About InFocus", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(MenuActions.portalSettings(_:)), ","))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide InFocus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit InFocus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(action("New Window", #selector(MenuActions.newPortalWindow(_:)), "n"))
        menu.addItem(withTitle: "New Tab", action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "t")
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(.separator())
        menu.addItem(action("Sign Out", #selector(MenuActions.signOut(_:)), ""))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = menu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        plain.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Find…", action: #selector(PortalWindowController.portalFind(_:)), keyEquivalent: "f")
        menu.addItem(withTitle: "Find Next", action: #selector(PortalWindowController.portalFindNext(_:)), keyEquivalent: "g")
        menu.addItem(withTitle: "Find Previous", action: #selector(PortalWindowController.portalFindPrevious(_:)), keyEquivalent: "G")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Reload Page", action: #selector(PortalWindowController.portalReload(_:)), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Actual Size", action: #selector(PortalWindowController.portalActualSize(_:)), keyEquivalent: "0")
        menu.addItem(withTitle: "Zoom In", action: #selector(PortalWindowController.portalZoomIn(_:)), keyEquivalent: "=")
        menu.addItem(withTitle: "Zoom Out", action: #selector(PortalWindowController.portalZoomOut(_:)), keyEquivalent: "-")
        menu.addItem(.separator())
        let full = menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    private static func historyMenu() -> NSMenu {
        let menu = NSMenu(title: "History")
        menu.addItem(withTitle: "Back", action: #selector(PortalWindowController.portalBack(_:)), keyEquivalent: "[")
        menu.addItem(withTitle: "Forward", action: #selector(PortalWindowController.portalForward(_:)), keyEquivalent: "]")
        menu.addItem(withTitle: "Home", action: #selector(PortalWindowController.portalHome(_:)), keyEquivalent: "H")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show All Tabs", action: #selector(NSWindow.toggleTabOverview(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(action("InFocus Portal", #selector(MenuActions.showPortal(_:)), "1"))
        let drive = action("Drive", #selector(MenuActions.showDrive(_:)), "D")
        menu.addItem(drive)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(action("InFocus Drive Help", #selector(MenuActions.showHelp(_:)), ""))
        NSApp.helpMenu = menu
        return menu
    }

    private static func action(_ title: String, _ selector: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = MenuActions.shared
        return item
    }
}

/// App-level menu commands (no window needed).
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()
    weak var drive: DriveController?

    @objc func newPortalWindow(_ sender: Any?) {
        if let drive { Windows.shared.newPortalWindow(drive, tabbedWith: nil) }
    }

    @objc func showPortal(_ sender: Any?) {
        if let drive { Windows.shared.showPortal(drive) }
    }

    @objc func portalSettings(_ sender: Any?) {
        guard let drive else { return }
        if let portal = AppConfig.shared.portalURL {
            Windows.shared.showPortal(drive, url: portal.appendingPathComponent("settings"))
        } else {
            Windows.shared.showMain(drive)
        }
    }

    @objc func showDrive(_ sender: Any?) {
        if let drive { Windows.shared.showMain(drive) }
    }

    @objc func showHelp(_ sender: Any?) {
        if let drive { Windows.shared.showHelp(drive) }
    }

    @objc func signOut(_ sender: Any?) {
        guard let drive else { return }
        Task { await PortalSignIn.shared.signOut(drive: drive) }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newPortalWindow(_:)), #selector(showPortal(_:)):
            return AppConfig.shared.portalURL != nil
        default:
            return true
        }
    }
}
