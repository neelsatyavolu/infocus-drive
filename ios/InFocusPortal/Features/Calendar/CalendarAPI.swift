import Foundation

/// The Calendar feature's Portal calls. DEBUG builds launched with `-InFocusStubSession`
/// read fictional fixtures instead (screenshots never touch the live Portal).
struct CalendarAPI: Sendable {
    var month: @Sendable (_ key: String) async throws -> CalendarMonth
    var announcements: @Sendable () async throws -> [ClassAnnouncement]
    var setLiked: @Sendable (_ id: String, _ liked: Bool) async throws -> AnnouncementLikeState
    var markRead: @Sendable (_ id: String) async throws -> Void
    var comment: @Sendable (_ id: String, _ body: String) async throws -> ClassAnnouncement.Comment
    var post: @Sendable (_ content: String) async throws -> Void

    static func live(_ client: PortalClient) -> CalendarAPI {
        struct Body: Encodable { let body: String }
        struct Content: Encodable { let content: String }
        struct Empty: Encodable {}
        return CalendarAPI(
            month: { key in
                try await client.get("api/master-calendar", query: [URLQueryItem(name: "month", value: key)])
            },
            announcements: { try await client.get("api/announcements") },
            setLiked: { id, liked in
                let path = "api/announcements/\(id)/like"
                if liked { return try await client.post(path, body: Empty()) }
                return try client.decode(AnnouncementLikeState.self, from: try await client.delete(path))
            },
            markRead: { id in try await client.post("api/announcements/\(id)/read", body: Empty()) },
            comment: { id, body in try await client.post("api/announcements/\(id)/comments", body: Body(body: body)) },
            post: { content in try await client.post("api/announcements", body: Content(content: content)) }
        )
    }

    /// Live, or the DEBUG fixtures when the shell runs on a stub session.
    static func current(_ client: PortalClient) -> CalendarAPI {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "InFocusStubSession") != nil { return .stub }
        #endif
        return .live(client)
    }
}
