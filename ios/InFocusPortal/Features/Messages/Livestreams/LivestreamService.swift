import Foundation

/// The Livestreams endpoints, or fictional data in the sample app (`SampleMode`).
struct LivestreamService: Sendable {
    var schedule: @Sendable () async throws -> LivestreamSchedule
    var requestSignup: @Sendable (_ eventId: String, _ note: String) async throws -> Void
    /// Managers: approve or deny someone's request.
    var review: @Sendable (_ signupId: String, _ approve: Bool) async throws -> Void
    /// Managers: create (`id` nil) or save an event.
    var saveEvent: @Sendable (_ id: String?, _ body: LivestreamEventBody) async throws -> Void
    var deleteEvent: @Sendable (_ id: String) async throws -> Void
    var completion: @Sendable () async throws -> LivestreamCompletion
    /// Managers: everyone, for crew and manager pickers.
    var members: @Sendable () async throws -> [PortalMember]
    /// Producers: appoint or remove a livestream manager.
    var addManager: @Sendable (_ userId: String) async throws -> Void
    var removeManager: @Sendable (_ userId: String) async throws -> Void

    static func live(_ client: PortalClient) -> LivestreamService {
        LivestreamService(
            schedule: { try await client.get("api/livestreams") },
            requestSignup: { eventId, note in
                try await client.post("api/livestreams/signups", body: SignupRequestBody(eventId: eventId, note: note))
            },
            review: { id, approve in
                let _: ReviewAnswer = try await client.patch("api/livestreams/signups/\(id)",
                                                             body: ["status": approve ? "APPROVED" : "DENIED"])
            },
            saveEvent: { id, body in
                if let id {
                    let _: ReviewAnswer = try await client.patch("api/livestreams/events/\(id)", body: body)
                } else {
                    let _: ReviewAnswer = try await client.post("api/livestreams/events", body: body)
                }
            },
            deleteEvent: { id in try await client.delete("api/livestreams/events/\(id)") },
            completion: { try await client.get("api/livestreams/completion") },
            members: { try await client.get("api/livestreams/members", as: MemberList.self).members },
            addManager: { id in try await client.post("api/livestreams/managers", body: ManagerBody(userId: id)) },
            removeManager: { id in
                try await client.delete("api/livestreams/managers", query: [URLQueryItem(name: "userId", value: id)])
            }
        )
    }

    static func resolve(_ client: PortalClient) -> LivestreamService {
        if FeatureStub.isOn { return .stub }
        return .live(client)
    }

    private struct ReviewAnswer: Decodable { let id: String }
}
