import Foundation

/// Addresses baked in at build time: Config/Portal.xcconfig writes the Portal
/// and Drive hosts into Info.plist (`InFocusPortalURL`, `InFocusDriveURL`), so
/// the source has no hostnames. Drive may be empty. `InFocusPortalLegacyHosts`
/// lists the Portal's old domains (space-separated): links there open the same
/// page on the Portal host, so pushes and links from before a move keep working.
struct AppConfig: Equatable {
    let portalURL: URL?
    let driveURL: URL?
    let legacyPortalHosts: [String]

    static let shared = AppConfig(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        portalURL = Self.origin(info["InFocusPortalURL"] as? String)
        driveURL = Self.origin(info["InFocusDriveURL"] as? String)
        legacyPortalHosts = Self.hosts(info["InFocusPortalLegacyHosts"] as? String)
    }

    /// "a.com b.com" → ["a.com", "b.com"], lowercased; blanks dropped.
    static func hosts(_ raw: String?) -> [String] {
        (raw ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.lowercased() }
    }

    /// `url` on an old Portal domain → the same page on the Portal host (same
    /// subdomain, path and query). Anything else, and the Drive website (which
    /// may live on an old domain), is returned as is.
    func onPortal(_ url: URL) -> URL {
        guard let portalHost else { return url }
        return Self.moved(url, to: portalHost, from: legacyPortalHosts, keeping: externalHosts)
    }

    static func moved(_ url: URL, to portalHost: String, from legacyHosts: [String],
                      keeping kept: Set<String> = AppConfig.shared.externalHosts) -> URL {
        guard let host = url.host?.lowercased(), !portalHost.isEmpty, !kept.contains(host),
              let legacy = legacyHosts.first(where: { host == $0 || host.hasSuffix("." + $0) }),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = String(host.dropLast(legacy.count)) + portalHost
        return parts.url ?? url
    }

    var portalHost: String? { portalURL?.host?.lowercased() }

    /// Where the app opens: the dashboard, like the Mac app's Portal window.
    var homeURL: URL? { portalURL?.appendingPathComponent("dashboard") }

    /// Hosts under the Portal's domain that still open in Safari (the Drive website).
    var externalHosts: Set<String> {
        Set([driveURL?.host?.lowercased()].compactMap { $0 })
    }

    /// An https origin (scheme + host + port, no path); http only for localhost.
    /// Empty values ("https://" with no host) are nil.
    static func origin(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              var parts = URLComponents(string: raw),
              let host = parts.host, !host.isEmpty,
              parts.scheme == "https" || (parts.scheme == "http" && host == "localhost") else {
            return nil
        }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// "1.0.0" (marketing version) for the user agent and push registration.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
