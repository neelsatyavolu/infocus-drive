import Foundation

/// Every Portal call the Admin dashboard makes (`app/(app)/admin/*`, `app/api/platform/*`).
/// In the sample app and DEBUG stub sessions (`SampleMode`) it answers from fictional fixtures.
struct AdminService {
    let client: PortalClient

    static var stubbed: Bool { SampleMode.isOn }

    func access() async throws -> PlatformAccess {
        if Self.stubbed { return try AdminFixtures.access() }
        return try await client.get("api/platform/me")
    }

    func stats() async throws -> PlatformStats {
        if Self.stubbed { return try AdminFixtures.stats() }
        return try await client.get("api/platform/stats")
    }

    // MARK: Access requests

    func accessRequests() async throws -> [AccessRequest] {
        if Self.stubbed { return try AdminFixtures.accessRequests() }
        return try await client.get("api/platform/access-requests")
    }

    /// Approve or deny one request (the Portal emails the person).
    func decide(_ requestId: String, approve: Bool) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let id: String; let status: String }
        let _: PortalJSON.Empty = try await client.patch("api/platform/access-requests",
                                                          body: Body(id: requestId, status: approve ? "APPROVED" : "DENIED"))
    }

    /// Approve every pending request at once; returns how many.
    func approveAllPending() async throws -> Int {
        if Self.stubbed { SampleMode.notSaved(); return 0 }
        struct Body: Encodable { var action = "APPROVE_ALL_PENDING" }
        struct Answer: Decodable { let approvedCount: Int? }
        let answer: Answer = try await client.patch("api/platform/access-requests", body: Body())
        return answer.approvedCount ?? 0
    }

    // MARK: People

    func people() async throws -> [PlatformPerson] {
        if Self.stubbed { return try AdminFixtures.people() }
        return try await client.get("api/platform/users")
    }

    /// Lets someone sign in (and optionally emails them an invite).
    func addPerson(name: String, email: String, sendInvite: Bool) async throws -> AddPersonResult {
        if Self.stubbed { SampleMode.notSaved(); return AddPersonResult(emailed: 0) }
        struct Body: Encodable { let email: String; let name: String; let sendInvite: Bool }
        return try await client.post("api/platform/allowed-emails", body: Body(email: email, name: name, sendInvite: sendInvite))
    }

    /// `nil` clears the nickname.
    func setNickname(_ nickname: String?, for userId: String) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable {
            let nickname: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(nickname, forKey: .nickname) // null clears it
            }
            enum CodingKeys: String, CodingKey { case nickname }
        }
        let _: PortalJSON.Empty = try await client.patch("api/platform/users/\(Self.segment(userId))", body: Body(nickname: nickname))
    }

    func deletePerson(_ userId: String) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        try await client.delete("api/platform/users/\(Self.segment(userId))")
    }

    // MARK: Producer team

    func roles() async throws -> [RoleAssignment] {
        if Self.stubbed { return try AdminFixtures.roles() }
        return try await client.get("api/platform/roles")
    }

    func setRole(_ role: AssignableRole, email: String) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let email: String; let role: String }
        let _: PortalJSON.Empty = try await client.post("api/platform/roles", body: Body(email: email, role: role.rawValue))
    }

    func removeRole(email: String) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        try await client.delete("api/platform/roles", query: [URLQueryItem(name: "email", value: email)])
    }

    // MARK: Program settings

    func programSettings() async throws -> ProgramSettings {
        if Self.stubbed { return ProgramSettings(cyclesPerSemester: 3, canEdit: true) }
        return try await client.get("api/platform/program-settings")
    }

    func setCyclesPerSemester(_ count: Int) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let cyclesPerSemester: Int }
        let _: PortalJSON.Empty = try await client.post("api/platform/program-settings", body: Body(cyclesPerSemester: count))
    }

    // MARK: Backups

    func backups() async throws -> BackupStatus {
        if Self.stubbed { return try AdminFixtures.backups() }
        return try await client.get("api/platform/backups")
    }

    func runBackup() async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        try await client.post("api/platform/backups/run", body: PortalJSON.EmptyBody())
    }

    /// A short-lived signed link to one backup file.
    func backupDownloadURL(key: String) async throws -> URL {
        struct Answer: Decodable { let url: URL }
        let answer: Answer = try await client.get("api/platform/backups/download", query: [URLQueryItem(name: "key", value: key)])
        return answer.url
    }

    // MARK: View as

    /// Whether View as is on and allowed for this session. The sample app never views as anyone.
    func viewAsStatus() async throws -> ViewAsStatus {
        if Self.stubbed { return .off }
        return try await client.get("api/auth/view-as/status")
    }

    func viewAsPeople() async throws -> [ViewAsPerson] {
        if Self.stubbed { return try AdminFixtures.viewAsPeople() }
        return try await client.get("api/auth/view-as/users")
    }

    /// One path segment. `PortalClient` escapes the path itself; an id never holds a "/".
    static func segment(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "")
    }
}
