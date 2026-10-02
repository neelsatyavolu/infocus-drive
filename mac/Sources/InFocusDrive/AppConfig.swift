import Foundation

/// Addresses baked in at build time: build.sh writes PORTAL_URL and DRIVE_URL
/// into Info.plist (`InFocusPortalURL`, `InFocusDriveURL`), so the source has
/// no hostnames. Either may be empty; then that part falls back (no Portal
/// window, or Drive's "enter the address" onboarding).
struct AppConfig: Equatable {
    let portalURL: URL?
    let driveURL: URL?

    static let shared = AppConfig(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        portalURL = Self.origin(info["InFocusPortalURL"] as? String)
        driveURL = Self.origin(info["InFocusDriveURL"] as? String)
    }

    var portalHost: String? { portalURL?.host?.lowercased() }

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
