import Foundation

/// Addresses baked in at build time: build.sh writes PORTAL_URL and DRIVE_URL
/// into Info.plist (`InFocusPortalURL`, `InFocusDriveURL`), so the source has
/// no hostnames. Either may be empty; then that part falls back (no Portal
/// window, or Drive's "enter the address" onboarding). `InFocusLegacyHosts`
/// (build.sh LEGACY_HOSTS, space-separated) lists old domains of both: their
/// links, the saved Drive address and Portal sign-in move to the current ones.
struct AppConfig: Equatable {
    let portalURL: URL?
    let driveURL: URL?
    let legacyHosts: [String]

    static let shared = AppConfig(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        portalURL = Self.origin(info["InFocusPortalURL"] as? String)
        driveURL = Self.origin(info["InFocusDriveURL"] as? String)
        let raw = info["InFocusLegacyHosts"] as? String ?? ""
        legacyHosts = raw.hasPrefix("__") ? [] : raw.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.lowercased() }
    }

    var portalHost: String? { portalURL?.host?.lowercased() }

    /// `url` on an old domain → the same page on the Portal's domain (same
    /// subdomain, path and query). Anything else is returned as is.
    func onPortal(_ url: URL) -> URL {
        guard let portalHost else { return url }
        return Self.moved(url, to: portalHost, from: legacyHosts)
    }

    /// True when `host` is one of the old domains or under one.
    func isLegacy(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return legacyHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func moved(_ url: URL, to portalHost: String, from legacyHosts: [String]) -> URL {
        guard let host = url.host?.lowercased(), !portalHost.isEmpty,
              let legacy = legacyHosts.first(where: { host == $0 || host.hasSuffix("." + $0) }),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = String(host.dropLast(legacy.count)) + portalHost
        return parts.url ?? url
    }

    /// An https origin (scheme + host + port, no path); http only for localhost.
    /// Empty values and unfilled build placeholders ("__PORTAL_URL__") are nil.
    static func origin(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.hasPrefix("__"),
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
}
