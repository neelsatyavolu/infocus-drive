import Foundation

/// One login in `GET api/vault` (`VaultEntrySummary`). Secrets never come with it:
/// each is revealed one field at a time, and the Portal logs every reveal.
struct VaultEntry: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: String?
    let username: String?
    let hasPassword: Bool
    let hasTotp: Bool
    let hasNotes: Bool
    let updatedAt: Date
    let updatedBy: String?
    let canDelete: Bool
    let canEdit: Bool
    let canShare: Bool
    /// How many people outside the vault see this login (0 for shared viewers).
    let sharedWith: Int

    /// The website as a link, only for http(s) (the Portal stores nothing else).
    var website: URL? {
        guard let url, let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return nil }
        return parsed
    }

    /// "youtube.com" from "https://www.youtube.com/…".
    var host: String? {
        website?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }
}

/// `GET api/vault/access`: this person's Passwords access, by the rule the `/passwords` page uses.
struct VaultAccess: Decodable, Sendable, Equatable {
    enum Level: String, Sendable {
        /// Associate producer and up (and still so under View as): every login.
        case full
        /// Only logins a producer shared with them (never while viewing as someone).
        case shared
        /// `"none"`: no Passwords page at all (named so it never reads as `Optional.none`).
        case noAccess = "none"
    }

    let level: Level
    /// Executive producers, the adviser and the super admin with full access.
    let canShare: Bool
    let canDeleteAny: Bool

    static let noAccess = VaultAccess(level: .noAccess, canShare: false, canDeleteAny: false)

    var isFull: Bool { level == .full }
    var canOpen: Bool { level != .noAccess }

    init(level: Level, canShare: Bool, canDeleteAny: Bool) {
        self.level = level
        self.canShare = canShare
        self.canDeleteAny = canDeleteAny
    }

    /// An unknown level from a newer Portal reads as no access.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = Level(rawValue: try c.decodeIfPresent(String.self, forKey: .level) ?? "") ?? .noAccess
        canShare = try c.decodeIfPresent(Bool.self, forKey: .canShare) ?? false
        canDeleteAny = try c.decodeIfPresent(Bool.self, forKey: .canDeleteAny) ?? false
    }

    private enum CodingKeys: String, CodingKey { case level, canShare, canDeleteAny }
}

/// `POST api/vault/<id>/reveal` with `{ field: "password" | "notes" }`.
struct VaultRevealedValue: Decodable, Sendable {
    let field: String
    let value: String
}

/// `POST api/vault/<id>/reveal` with `{ field: "totp" }`: the current code and how long it lasts.
struct VaultTotp: Decodable, Sendable, Equatable {
    let code: String
    let secondsRemaining: Int
    let period: Int

    /// "123456" → "123 456" (any other shape as is).
    static func grouped(_ code: String) -> String {
        guard code.count > 3, code.allSatisfy(\.isNumber) else { return code }
        return "\(code.prefix(3)) \(code.dropFirst(3))"
    }
}

/// `GET api/vault/<id>/activity` rows.
struct VaultActivity: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let action: String
    let actor: String
    let createdAt: Date

    /// `VAULT_ACTION_LABELS`.
    var label: String {
        switch action {
        case "CREATE": "Added"
        case "IMPORT": "Imported"
        case "UPDATE": "Edited"
        case "DELETE": "Deleted"
        case "REVEAL_PASSWORD": "Viewed password"
        case "REVEAL_NOTES": "Viewed notes"
        case "VIEW_2FA_CODE": "Viewed 2FA code"
        case "SHARE": "Changed sharing"
        default: action.capitalized
        }
    }
}

/// `GET api/vault/people` and `GET|PUT api/vault/<id>/shares`.
struct VaultPeople: Decodable, Sendable {
    struct Person: Decodable, Sendable, Identifiable, Hashable {
        let id: String
        let name: String
    }

    let people: [Person]
}

/// A saved write-only secret while editing: keep it, type a new one, or remove it.
enum VaultSecretMode: Sendable, Equatable {
    case keep, replace, remove
}

/// The body of `POST api/vault` (add) and `PATCH api/vault/<id>` (edit). On an edit an
/// omitted field stays as it was and an empty string clears it (`vaultEntryUpdateSchema`).
struct VaultEntryInput: Encodable, Sendable, Equatable {
    var name: String
    var url: String?
    var username: String?
    var password: String?
    var totp: String?
    var notes: String?

    static let nameMax = 120

    /// The web form's rule (`secretValue`): remove sends "", keep (or an empty new value
    /// while editing) leaves the field out, anything else sends the new value.
    static func secret(_ mode: VaultSecretMode, _ value: String, editing: Bool) -> String? {
        switch mode {
        case .remove: return ""
        case .keep: return nil
        case .replace: return editing && value.isEmpty ? nil : value
        }
    }

    /// Strong random password, like the web's "Suggest strong password": 20 characters
    /// from letters, digits and symbols, with at least one of each.
    static func strongPassword(length: Int = 20) -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let digits = Array("23456789"), symbols = Array("!@#$%^&*-_=+?")
        let all = lower + upper + digits + symbols
        var characters = [lower, upper, digits, symbols].compactMap { $0.randomElement() }
        while characters.count < length { characters.append(all.randomElement()!) }
        return String(characters.shuffled())
    }
}

/// Search on name, website and username, plus the Shared filter (`filterVaultEntries`).
enum VaultSearch {
    static func filter(_ entries: [VaultEntry], _ query: String, sharedOnly: Bool) -> [VaultEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            if sharedOnly && entry.sharedWith <= 0 { return false }
            guard !needle.isEmpty else { return true }
            return [entry.name, entry.url ?? "", entry.username ?? ""].contains { $0.lowercased().contains(needle) }
        }
    }
}
