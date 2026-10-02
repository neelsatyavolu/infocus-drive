import Foundation

/// The Announcements feature's Portal calls. DEBUG builds launched with `-InFocusStubSession`
/// read fictional fixtures instead (screenshots never touch the live Portal).
struct AnnouncementsAPI: Sendable {
    var slackFeed: @Sendable () async throws -> SlackFeed
    var submitted: @Sendable () async throws -> SubmittedBoard
    var deleteSubmitted: @Sendable (_ id: String) async throws -> Void
    var invite: @Sendable (_ emails: String, _ sendEmail: Bool, _ duration: InviteDuration) async throws -> SubmittedInvite
    var pa: @Sendable () async throws -> PAPage
    var savePA: @Sendable (_ date: String, _ content: String, _ version: Int) async throws -> PAPage
    var regeneratePA: @Sendable (_ date: String, _ version: Int) async throws -> PAPage

    static func live(_ client: PortalClient) -> AnnouncementsAPI {
        struct ID: Encodable { let id: String }
        struct Invite: Encodable { let emails: String; let sendEmail: Bool; let duration: String }
        struct Save: Encodable { let date: String; let content: String; let version: Int }
        struct Regenerate: Encodable { let date: String; let version: Int }
        return AnnouncementsAPI(
            slackFeed: { try await client.get("api/announcements/slack") },
            submitted: { try await client.get("api/announcements/submitted/grouped") },
            deleteSubmitted: { id in _ = try await client.delete("api/announcements/submitted", body: ID(id: id)) },
            invite: { emails, sendEmail, duration in
                try await client.post("api/announcements/submitted/invite",
                                      body: Invite(emails: emails, sendEmail: sendEmail, duration: duration.rawValue))
            },
            pa: { try await client.get("api/announcements/pa") },
            savePA: { date, content, version in
                try await client.patch("api/announcements/pa", body: Save(date: date, content: content, version: version))
            },
            regeneratePA: { date, version in
                try await client.post("api/announcements/pa", body: Regenerate(date: date, version: version))
            }
        )
    }

    /// Live, or the DEBUG fixtures when the shell runs on a stub session.
    static func current(_ client: PortalClient) -> AnnouncementsAPI {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "InFocusStubSession") != nil { return .stub }
        #endif
        return .live(client)
    }
}
