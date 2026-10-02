import Foundation

/// Addresses baked in at build time: Config/Portal.xcconfig writes the Portal
/// and Drive hosts into Info.plist (`InFocusPortalURL`, `InFocusDriveURL`), so
/// the source has no hostnames. Drive may be empty.
struct AppConfig: Equatable {
    let portalURL: URL?
    let driveURL: URL?

    static let shared = AppConfig(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        portalURL = Self.origin(info["InFocusPortalURL"] as? String)
        driveURL = Self.origin(info["InFocusDriveURL"] as? String)
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
