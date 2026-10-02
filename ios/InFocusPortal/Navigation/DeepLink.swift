import Foundation

/// Maps a Portal URL (from a notification or a link) to a native tab and
/// screen. Each feature parses its own paths (`WorkRoute.deepLink` …); a page
/// no feature claims opens in the in-app Portal web view.
enum DeepLink {
    typealias Parser = (_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch?

    /// Tried in order; the first match wins.
    static let parsers: [Parser] = [
        WorkRoute.deepLink, AnnouncementsRoute.deepLink, CalendarRoute.deepLink,
        GradeEditorRoute.deepLink, GradesRoute.deepLink, MessagesRoute.deepLink,
        PackageCyclesRoute.deepLink, PublishingRoute.deepLink, MoreRoute.deepLink,
    ]

    static func resolve(_ url: URL, portal: URL) -> DeepLinkMatch {
        let portalHost = portal.host?.lowercased() ?? ""
        guard let host = url.host?.lowercased(), PortalNavigation.isPortal(host, portalHost: portalHost) else {
            return DeepLinkMatch(tab: nil, route: .portal(PortalPage(url: url)))
        }
        var path = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Subdomains are Portal surfaces of their own (equipment., grades., …).
        if host != portalHost, let surface = host.split(separator: ".").first {
            path = surface == "grades" && path.isEmpty ? ["grades"] : [String(surface)] + path
        }
        if path.isEmpty || path == ["dashboard"] { return DeepLinkMatch(tab: .home, route: nil) }
        for parse in parsers {
            if let match = parse(path, query) { return match }
        }
        return DeepLinkMatch(tab: nil, route: .portal(PortalPage(url: url)))
    }
}
