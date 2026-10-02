import Foundation

/// The Livestreams endpoints, or stub data for DEBUG screenshots (`FeatureStub`).
struct LivestreamService: Sendable {
    var schedule: @Sendable () async throws -> LivestreamSchedule
    var requestSignup: @Sendable (_ eventId: String, _ note: String) async throws -> Void
    /// Managers: approve or deny someone's request.
    var review: @Sendable (_ signupId: String, _ approve: Bool) async throws -> Void

    static func live(_ client: PortalClient) -> LivestreamService {
        LivestreamService(
            schedule: { try await client.get("api/livestreams") },
            requestSignup: { eventId, note in
                try await client.post("api/livestreams/signups", body: SignupRequestBody(eventId: eventId, note: note))
            },
            review: { id, approve in
                let _: ReviewAnswer = try await client.patch("api/livestreams/signups/\(id)",
                                                             body: ["status": approve ? "APPROVED" : "DENIED"])
            }
        )
    }

    static func resolve(_ client: PortalClient) -> LivestreamService {
        #if DEBUG
        if FeatureStub.isOn { return .stub }
        #endif
        return .live(client)
    }

    private struct ReviewAnswer: Decodable { let id: String }
}
