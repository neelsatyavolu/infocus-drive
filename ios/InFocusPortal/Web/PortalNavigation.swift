import Foundation

/// Where a top-level navigation goes. Portal pages (the Portal host and its
/// subdomains: grades., equipment., …) stay in the app; Google sign-in is
/// replaced by the native hand-off (Google refuses embedded web views);
/// the Portal's Sign out runs natively (so this device stops getting
/// notifications first); everything else leaves the app.
enum PortalNavigation: Equatable {
    case inApp, signIn, signOut, external

    static let googleStartPath = "/api/auth/google/start"
    static let signOutPath = "/api/auth/sign-out"
    static let signInPagePath = "/sign-in"

    static func isPortal(_ host: String?, portalHost: String) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty, !portalHost.isEmpty else { return false }
        return host == portalHost || host.hasSuffix("." + portalHost)
    }

    /// `externalHosts` always leave the app even under the Portal's domain
    /// (the Drive website).
    static func decide(_ url: URL, portalHost: String, externalHosts: Set<String> = []) -> PortalNavigation {
        switch url.scheme?.lowercased() {
        case "about", "blob", "data":
            return .inApp
        case "http", "https":
            let host = url.host?.lowercased() ?? ""
            guard !externalHosts.contains(host), isPortal(host, portalHost: portalHost) else { return .external }
            switch url.path {
            case googleStartPath: return .signIn
            case signOutPath: return .signOut
            default: return .inApp
            }
        default:
            return .external // mailto:, tel:, other apps
        }
    }

    /// The Portal page a sign-in link asked to return to (`returnTo=/path`),
    /// only if it's a plain path on the Portal.
    static func returnTo(from url: URL, portal: URL) -> URL? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "returnTo" })?.value,
              raw.hasPrefix("/"), !raw.hasPrefix("//"), !raw.contains("\\"),
              let target = URL(string: raw, relativeTo: portal)?.absoluteURL,
              target.host == portal.host else { return nil }
        return target
    }

    /// The Portal's sign-in page (where it sends a signed-out visitor).
    static func isSignInPage(_ url: URL?, portalHost: String) -> Bool {
        guard let url else { return false }
        return isPortal(url.host, portalHost: portalHost) && url.path == signInPagePath
    }
}
