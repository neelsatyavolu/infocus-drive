import AppKit
import SwiftUI
import WebKit

/// A Portal window: the Portal page under a slim native title bar (Back,
/// Forward, Reload, the page title, Find and a Drive chip). The title bar
/// takes the page's own background, so it matches the Portal's dark or light
/// theme. Windows tab natively (Cmd+T); closing the last one only hides it,
/// keeping the page loaded for an instant reopen.
@MainActor
final class PortalWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let web: PortalWebController
    private let drive: DriveController
    private var observations: [NSKeyValueObservation] = []
    private var backItem: NSToolbarItem?
    private var forwardItem: NSToolbarItem?
    private var searchItem: NSSearchToolbarItem?
    private var findText = ""

    private static let ink = NSColor.hex(0x0A0A0A) // the Portal's default dark background

    private enum Item {
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let reload = NSToolbarItem.Identifier("reload")
        static let find = NSToolbarItem.Identifier("find")
        static let drive = NSToolbarItem.Identifier("drive")
    }

    init(portal: URL, drive: DriveController, url: URL?) {
        self.drive = drive
        web = PortalWebController(portal: portal, drive: drive)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "InFocus"
        window.tabbingIdentifier = "portal"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.contentView = web.webView
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "portal")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        applyPageColor(Self.ink)
        if !window.setFrameUsingName("PortalWindow") { window.center() }
        window.setFrameAutosaveName("PortalWindow")
        observePage()
        web.load(url ?? portal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Page state

    private func observePage() {
        let webView = web.webView
        observations = [
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.updateTitle() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.updateNavigation() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.updateNavigation() } },
            webView.observe(\.underPageBackgroundColor) { [weak self] view, _ in
                Task { @MainActor in self?.applyPageColor(view.underPageBackgroundColor) }
            },
        ]
    }

    private func updateTitle() {
        let title = web.webView.title ?? ""
        window?.title = title.isEmpty ? "InFocus" : title
    }

    private func updateNavigation() {
        backItem?.isEnabled = web.webView.canGoBack
        forwardItem?.isEnabled = web.webView.canGoForward
    }

    /// Title bar = page background; dark or light controls to match.
    private func applyPageColor(_ color: NSColor?) {
        guard let window, let color = color?.usingColorSpace(.sRGB), color.alphaComponent > 0 else { return }
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        window.backgroundColor = color
        window.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
    }

    // MARK: Actions (menus and toolbar; unique names so other responders don't catch them)

    @objc func portalBack(_ sender: Any?) { web.webView.goBack() }
    @objc func portalForward(_ sender: Any?) { web.webView.goForward() }
    @objc func portalReload(_ sender: Any?) { web.webView.reload() }
    @objc func portalHome(_ sender: Any?) { web.load(web.portal) }
    @objc func portalZoomIn(_ sender: Any?) { web.webView.pageZoom = min(3, web.webView.pageZoom + 0.1) }
    @objc func portalZoomOut(_ sender: Any?) { web.webView.pageZoom = max(0.5, web.webView.pageZoom - 0.1) }
    @objc func portalActualSize(_ sender: Any?) { web.webView.pageZoom = 1 }
    @objc func portalFind(_ sender: Any?) { searchItem?.beginSearchInteraction() }
    @objc func portalFindNext(_ sender: Any?) { find(backwards: false) }
    @objc func portalFindPrevious(_ sender: Any?) { find(backwards: true) }

    override func newWindowForTab(_ sender: Any?) {
        Windows.shared.newPortalWindow(drive, tabbedWith: self)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        findText = sender.stringValue
        find(backwards: false)
    }

    private func find(backwards: Bool) {
        guard !findText.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        web.webView.find(findText, configuration: config) { result in
            if !result.matchFound { NSSound.beep() }
        }
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Windows.shared.portalShouldClose(self)
    }

    func windowWillClose(_ notification: Notification) {
        Windows.shared.portalClosed(self)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.back, Item.forward, Item.reload, .flexibleSpace, Item.find, Item.drive]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Item.back:
            backItem = button(id, "Back", "chevron.left", #selector(portalBack(_:)), navigational: true)
            backItem?.isEnabled = false
            return backItem
        case Item.forward:
            forwardItem = button(id, "Forward", "chevron.right", #selector(portalForward(_:)), navigational: true)
            forwardItem?.isEnabled = false
            return forwardItem
        case Item.reload:
            return button(id, "Reload", "arrow.clockwise", #selector(portalReload(_:)), navigational: true)
        case Item.find:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Find on page"
            item.searchField.sendsWholeSearchString = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            searchItem = item
            return item
        case Item.drive:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Drive"
            item.toolTip = "Open the Drive window"
            item.view = NSHostingView(rootView: DriveChip(drive: drive))
            return item
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String,
                        _ action: Selector, navigational: Bool) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        item.isNavigational = navigational
        item.autovalidates = false
        return item
    }
}

/// Drive's state in the Portal title bar; click for the Drive window.
private struct DriveChip: View {
    @ObservedObject var drive: DriveController

    var body: some View {
        Button { Windows.shared.showMain(drive) } label: {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive").font(.system(size: 11, weight: .medium))
                Text("Drive").font(.lexend(11.5, .medium))
                StatePill(drive: drive)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Open the Drive window")
    }
}
