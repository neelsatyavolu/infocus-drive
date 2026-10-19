import Foundation

/// `GET|PATCH api/profile`: the nickname, beside the Google account it can't overwrite.
struct ProfileInfo: Decodable, Sendable, Equatable {
    let email: String?
    let name: String?
    let nickname: String?

    static let nicknameMax = 60
}

/// `GET|PUT api/notification-preferences`. A PUT always sends every field.
struct NotificationPreferences: Codable, Sendable, Equatable {
    var emailEnabled = true
    var notificationEmail: String?
    var browserEnabled = false
    var emailAnnouncementsEnabled = true
    var emailCommentsEnabled = true
    var emailGradesEnabled = false
    var browserAnnouncementsEnabled = true
    var browserCommentsEnabled = true
    var browserGradesEnabled = false

    init() {}

    /// Missing fields keep the Portal's defaults (`DEFAULT_SETTINGS`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = NotificationPreferences()
        emailEnabled = try c.decodeIfPresent(Bool.self, forKey: .emailEnabled) ?? base.emailEnabled
        notificationEmail = try c.decodeIfPresent(String.self, forKey: .notificationEmail)
        browserEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserEnabled) ?? base.browserEnabled
        emailAnnouncementsEnabled = try c.decodeIfPresent(Bool.self, forKey: .emailAnnouncementsEnabled) ?? base.emailAnnouncementsEnabled
        emailCommentsEnabled = try c.decodeIfPresent(Bool.self, forKey: .emailCommentsEnabled) ?? base.emailCommentsEnabled
        emailGradesEnabled = try c.decodeIfPresent(Bool.self, forKey: .emailGradesEnabled) ?? base.emailGradesEnabled
        browserAnnouncementsEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserAnnouncementsEnabled) ?? base.browserAnnouncementsEnabled
        browserCommentsEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserCommentsEnabled) ?? base.browserCommentsEnabled
        browserGradesEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserGradesEnabled) ?? base.browserGradesEnabled
    }

    /// `notificationEmail` goes out as null when cleared (the schema takes null, not a missing key).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(emailEnabled, forKey: .emailEnabled)
        try c.encode(notificationEmail, forKey: .notificationEmail)
        try c.encode(browserEnabled, forKey: .browserEnabled)
        try c.encode(emailAnnouncementsEnabled, forKey: .emailAnnouncementsEnabled)
        try c.encode(emailCommentsEnabled, forKey: .emailCommentsEnabled)
        try c.encode(emailGradesEnabled, forKey: .emailGradesEnabled)
        try c.encode(browserAnnouncementsEnabled, forKey: .browserAnnouncementsEnabled)
        try c.encode(browserCommentsEnabled, forKey: .browserCommentsEnabled)
        try c.encode(browserGradesEnabled, forKey: .browserGradesEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case emailEnabled, notificationEmail, browserEnabled
        case emailAnnouncementsEnabled, emailCommentsEnabled, emailGradesEnabled
        case browserAnnouncementsEnabled, browserCommentsEnabled, browserGradesEnabled
    }

    /// The email categories (Announcements, Comments, Grades).
    enum Category: String, CaseIterable, Identifiable {
        case announcements, comments, grades
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    func email(_ category: Category) -> Bool {
        switch category {
        case .announcements: emailAnnouncementsEnabled
        case .comments: emailCommentsEnabled
        case .grades: emailGradesEnabled
        }
    }

    func settingEmail(_ category: Category, _ on: Bool) -> NotificationPreferences {
        var next = self
        switch category {
        case .announcements: next.emailAnnouncementsEnabled = on
        case .comments: next.emailCommentsEnabled = on
        case .grades: next.emailGradesEnabled = on
        }
        return next
    }
}

/// A kiosk PIN (`GET|POST api/class-board/pin`, `api/livestreams/pin`). The endpoint
/// decides who may see it; a refusal hides the row.
struct AccessPin: Decodable, Sendable, Equatable {
    let pin: String?
}

enum AccessPinKind: String, CaseIterable, Identifiable, Sendable {
    case classBoard, livestream

    var id: String { rawValue }

    var path: String {
        switch self {
        case .classBoard: "api/class-board/pin"
        case .livestream: "api/livestreams/pin"
        }
    }

    var title: String {
        switch self {
        case .classBoard: "Class Board PIN"
        case .livestream: "Livestream dashboard PIN"
        }
    }

    var replaceWarning: String {
        switch self {
        case .classBoard: "Devices using the old one will need the new PIN."
        case .livestream: "Anyone using the old one will need the new PIN."
        }
    }
}

/// `GET|PUT|DELETE api/profile/signature` (executive producers and the super admin):
/// a PNG data URL, dark ink on transparent.
struct SignatureInfo: Decodable, Sendable, Equatable {
    let signature: String?

    static let prefix = "data:image/png;base64,"
    static let maxLength = 400_000

    /// The PNG inside the data URL, if it is one.
    static func pngData(_ dataURL: String?) -> Data? {
        guard let dataURL, dataURL.hasPrefix(prefix) else { return nil }
        return Data(base64Encoded: String(dataURL.dropFirst(prefix.count)))
    }

    static func dataURL(png: Data) -> String? {
        let url = prefix + png.base64EncodedString()
        return url.count <= maxLength ? url : nil
    }
}

/// Settings' Portal calls. The sample app may read and save its profile and
/// notification preferences (the account allows them); PINs and signature never load there.
struct SettingsService {
    let client: PortalClient

    func profile() async throws -> ProfileInfo {
        try await client.get("api/profile")
    }

    func saveNickname(_ nickname: String?) async throws -> ProfileInfo {
        struct Body: Encodable {
            let nickname: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(nickname, forKey: .nickname)
            }
            enum CodingKeys: String, CodingKey { case nickname }
        }
        return try await client.patch("api/profile", body: Body(nickname: nickname))
    }

    func notifications() async throws -> NotificationPreferences {
        try await client.get("api/notification-preferences")
    }

    func saveNotifications(_ preferences: NotificationPreferences) async throws -> NotificationPreferences {
        try await client.put("api/notification-preferences", body: preferences)
    }

    func sendTestEmail() async throws {
        try await client.post("api/notification-preferences/test-email", body: PortalJSON.EmptyBody())
    }

    /// nil when this person can't see the PIN (or in the sample app).
    func pin(_ kind: AccessPinKind) async -> AccessPin? {
        guard !SampleMode.isOn else { return nil }
        return try? await client.get(kind.path)
    }

    func renewPin(_ kind: AccessPinKind) async throws -> AccessPin {
        try await client.post(kind.path, body: PortalJSON.EmptyBody())
    }

    /// nil when this person has no signature section.
    func signature() async -> SignatureInfo? {
        guard !SampleMode.isOn else { return nil }
        return try? await client.get("api/profile/signature")
    }

    func saveSignature(_ dataURL: String) async throws -> SignatureInfo {
        struct Body: Encodable { let signature: String }
        return try await client.put("api/profile/signature", body: Body(signature: dataURL))
    }

    func deleteSignature() async throws {
        try await client.delete("api/profile/signature")
    }
}
