import CryptoKit
import Foundation

/// Values baked in at build time: build.sh writes DRIVE_URL into Info.plist
/// (`InFocusDriveURL`), so the source has no hostnames. It may be empty; then
/// Drive's "enter the address" onboarding shows. `InFocusLegacyHosts` (build.sh
/// LEGACY_HOSTS, space-separated) lists old Drive domains: a saved address on
/// one moves to the current one. `InFocusBackupUserHashes` (build.sh
/// BACKUP_USERS) are SHA-256 hashes of the Drive usernames that see Mac backup.
struct AppConfig: Equatable {
    let driveURL: URL?
    let legacyHosts: [String]
    let backupUserHashes: Set<String>

    static let shared = AppConfig(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        driveURL = Self.origin(info["InFocusDriveURL"] as? String)
        legacyHosts = Self.words(info["InFocusLegacyHosts"] as? String)
        backupUserHashes = Set(Self.words(info["InFocusBackupUserHashes"] as? String))
    }

    /// True when `host` is one of the old domains or under one.
    func isLegacy(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return legacyHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Mac backup is switched on for this Drive username.
    func backupEnabled(for username: String) -> Bool {
        backupUserHashes.contains(Self.hash(username))
    }

    static func hash(_ username: String) -> String {
        SHA256.hash(data: Data(username.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Space- or comma-separated lowercase words; an unfilled placeholder is empty.
    private static func words(_ raw: String?) -> [String] {
        let raw = raw ?? ""
        if raw.hasPrefix("__") { return [] }
        return raw.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.lowercased() }
    }

    /// An https origin (scheme + host + port, no path); http only for localhost.
    /// Empty values and unfilled build placeholders ("__DRIVE_URL__") are nil.
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
