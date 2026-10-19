import Foundation

/// `GET api/platform/me`: who you are and what Admin lets you do.
struct PlatformAccess: Decodable, Sendable, Equatable {
    struct Permissions: Decodable, Sendable, Equatable {
        /// Executive producer and up: Admin's lists, people and access requests.
        var canManageAllowedEmails = false
        /// Super admin (the adviser counts): roles, backups, integrations, View as.
        var canManagePlatformRoles = false

        init(canManageAllowedEmails: Bool = false, canManagePlatformRoles: Bool = false) {
            self.canManageAllowedEmails = canManageAllowedEmails
            self.canManagePlatformRoles = canManagePlatformRoles
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            canManageAllowedEmails = try c.decodeIfPresent(Bool.self, forKey: .canManageAllowedEmails) ?? false
            canManagePlatformRoles = try c.decodeIfPresent(Bool.self, forKey: .canManagePlatformRoles) ?? false
        }

        private enum CodingKeys: String, CodingKey { case canManageAllowedEmails, canManagePlatformRoles }
    }

    let email: String?
    let role: String?
    let permissions: Permissions
}

/// `GET api/platform/stats` (only the totals Admin shows).
struct PlatformStats: Decodable, Sendable, Equatable {
    struct Totals: Decodable, Sendable, Equatable {
        let users: Int
        let workspaces: Int
        let projects: Int
        let activeMedia: Int
        let versions: Int
        let comments: Int
        let activeShareLinks: Int
    }

    struct Storage: Decodable, Sendable, Equatable {
        let estimatedBytes: Int64
        let isEstimated: Bool
    }

    let totals: Totals
    let storage: Storage
}

/// One row of `GET api/platform/access-requests` (pending first).
struct AccessRequest: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let email: String
    let name: String?
    /// PENDING, APPROVED or DENIED.
    let status: String
    let requestedAt: Date
    let decidedAt: Date?
    let decidedByEmail: String?

    var isPending: Bool { status == "PENDING" }
    var label: String { name?.isEmpty == false ? name! : email }
}

/// One row of `GET api/platform/users` (names as stored).
struct PlatformPerson: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let email: String?
    let name: String?
    let nickname: String?
    let createdAt: Date

    /// Same order as the web's `personLabel`: nickname, name, email.
    var label: String {
        [nickname, name, email].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Unnamed"
    }

    /// A row created when access was approved, before the person ever signed in.
    var hasSignedIn: Bool { !id.hasPrefix("pending_") }
}

/// One row of `GET api/platform/roles`.
struct RoleAssignment: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let email: String
    /// A `PlatformRole` raw value.
    let role: String
    let createdAt: Date?

    var platformRole: PlatformRole? { PlatformRole(rawValue: role) }
}

/// `GET api/platform/program-settings`.
struct ProgramSettings: Decodable, Sendable, Equatable {
    let cyclesPerSemester: Int
    let canEdit: Bool?

    static let range = 1...8
}

/// `GET api/platform/backups` (super admin).
struct BackupStatus: Decodable, Sendable, Equatable {
    struct Latest: Decodable, Sendable, Equatable {
        let ok: Bool
        let at: Date
        let key: String?
        let bytes: Int64?
        let error: String?
    }

    struct Dump: Decodable, Sendable, Equatable, Identifiable {
        let key: String
        let lastModified: Date
        let bytes: Int64
        var id: String { key }

        /// The file name without its folders.
        var fileName: String { key.split(separator: "/").last.map(String.init) ?? key }
    }

    let configured: Bool
    let latest: Latest?
    let dumps: [Dump]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        latest = try c.decodeIfPresent(Latest.self, forKey: .latest)
        dumps = try c.decodeIfPresent([Dump].self, forKey: .dumps) ?? []
    }

    private enum CodingKeys: String, CodingKey { case configured, latest, dumps }
}

/// One person in `GET api/auth/view-as/users` (display names already applied).
struct ViewAsPerson: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String?
    let email: String?

    var label: String { name?.isEmpty == false ? name! : email ?? "Unnamed" }
}

/// The parts of a `POST api/platform/allowed-emails` answer the app reads.
struct AddPersonResult: Decodable, Sendable {
    let emailed: Int?
}

/// The roles Admin can hand out (`POST api/platform/roles` refuses super admin).
enum AssignableRole: String, CaseIterable, Identifiable, Sendable {
    case associateProducer = "ASSOCIATE_PRODUCER"
    case executiveProducer = "EXECUTIVE_PRODUCER"
    case adviser = "ADVISER"

    var id: String { rawValue }
    var label: String { PlatformRole(rawValue: rawValue)?.label ?? rawValue }
}

/// Words and numbers Admin shows.
enum AdminFormat {
    /// "1.25 GB", like the web's `formatStorage`.
    static func storage(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1e12 { return String(format: "%.2f TB", value / 1e12) }
        if value >= 1e9 { return String(format: "%.2f GB", value / 1e9) }
        if value >= 1e6 { return String(format: "%.2f MB", value / 1e6) }
        return "\(Int((value / 1e3).rounded())) KB"
    }

    /// "Oct 14, 3:05 PM", with the year when it isn't this year.
    static func when(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "MMM d, h:mm a" : "MMM d, yyyy, h:mm a"
        return formatter.string(from: date)
    }

    static func isEmail(_ text: String) -> Bool {
        text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
}
