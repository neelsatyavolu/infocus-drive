import Foundation

/// A Portal member as the manager pickers list them (`api/livestreams/members`,
/// `api/platform/users`, and the `user` on a manager row).
struct PortalMember: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String?
    var nickname: String?
    let email: String?

    /// Nickname, then name, then email, like the web's pickers.
    var label: String {
        if let nickname = nickname?.trimmingCharacters(in: .whitespaces), !nickname.isEmpty { return nickname }
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return email ?? "Member"
    }

    /// Nickname, legal name or email, so either name finds the person.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return [nickname, name, email].contains { $0?.localizedCaseInsensitiveContains(needle) == true }
    }
}

/// An appointed equipment or livestream manager (`GET …/managers`).
struct ManagerRow: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let userId: String
    let createdAt: Date
    let user: PortalMember?

    var label: String { user?.label ?? "Member" }
}

/// `{ managers }` from `api/equipment/manage/managers`.
struct ManagerList: Decodable, Sendable {
    let managers: [ManagerRow]
}

/// `{ members }` from `api/livestreams/members`.
struct MemberList: Decodable, Sendable {
    let members: [PortalMember]
}

/// `{ userId }` for appointing a manager.
struct ManagerBody: Encodable, Sendable {
    let userId: String
}
