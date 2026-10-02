import SwiftUI
import Observation

/// The selected tab and each tab's navigation path. Push from anywhere:
///
///     @Environment(Router.self) private var router
///     router.push(.work(.group(rowId: id, stage: nil)))
///     router.openPortal("announcements/submitted", title: "Submitted")
@MainActor @Observable
final class Router {
    var selectedTab: AppTab = .home
    private(set) var paths: [AppTab: [Route]] = [:]
    /// Where `openPortal` resolves relative paths.
    var portal: URL?
    /// The App Review sample account: only Home, Settings and Portal pages (the
    /// Portal sends anything else back to its dashboard).
    var sampleOnly = false

    func allows(_ tab: AppTab) -> Bool {
        !sampleOnly || tab == .home || tab == .more
    }

    func allows(_ route: Route) -> Bool {
        guard sampleOnly else { return true }
        switch route {
        case .more(.settings), .portal: return true
        default: return false
        }
    }

    func path(_ tab: AppTab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    /// Tapping the selected tab again goes back to its root (iOS convention).
    func select(_ tab: AppTab) {
        if tab == selectedTab { paths[tab] = [] }
        selectedTab = tab
    }

    func push(_ route: Route, on tab: AppTab? = nil) {
        guard allows(route) else { return }
        let tab = tab ?? selectedTab
        paths[tab, default: []].append(route)
    }

    /// A Portal page in the in-app web view, on the current tab.
    func openPortal(_ path: String, title: String? = nil) {
        guard let portal else { return }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: trimmed, relativeTo: portal)?.absoluteURL else { return }
        push(.portal(PortalPage(url: url, title: title)))
    }

    /// A deep link: switch tab, reset it to its root, then push the screen.
    func open(_ url: URL) {
        guard let portal else { return }
        let match = DeepLink.resolve(url, portal: portal)
        let tab = match.tab ?? selectedTab
        guard allows(tab), match.route.map(allows) ?? true else { // not for this account: Home
            selectedTab = .home
            paths[.home] = []
            return
        }
        selectedTab = tab
        paths[tab] = match.route.map { [$0] } ?? []
    }

    func reset() {
        paths = [:]
        selectedTab = .home
        sampleOnly = false
    }
}
