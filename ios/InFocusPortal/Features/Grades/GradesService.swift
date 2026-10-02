import Foundation

/// Every Portal call the Grades area makes. In the sample app
/// (`SampleMode`) it answers from fictional fixtures instead, so the
/// screens can be shown without a Portal.
struct GradesService {
    let client: PortalClient

    func grades() async throws -> GradesMe {
        if Self.stubbed { return try GradesFixtures.decode(GradesMe.self, GradesFixtures.gradesJSON) }
        return try await client.get("api/grades/me")
    }

    func extensionRequests() async throws -> ExtensionRequestsPayload {
        if Self.stubbed {
            let producer = ["associate", "producer", "executive", "admin"].contains(UserDefaults.standard.string(forKey: "InFocusStubSession") ?? "associate")
            return try GradesFixtures.decode(ExtensionRequestsPayload.self,
                                             producer ? GradesFixtures.producerExtensionsJSON : GradesFixtures.extensionsJSON)
        }
        return try await client.get("api/extensions/requests")
    }

    /// The cycle the student is working on now (preselects the request form).
    func currentCycle() async -> Int? {
        if Self.stubbed { return 2 }
        struct Gates: Decodable { let cycleNumber: Int? }
        return try? await client.get("api/package-cycle/stage", as: Gates.self).cycleNumber
    }

    func requestExtension(_ request: NewExtensionRequest) async throws {
        if Self.stubbed { return }
        let _: PortalJSON.Empty = try await client.post("api/extensions/requests", body: request)
    }

    /// A group member agrees to (or declines) a teammate's request.
    func respondAsMember(requestId: String, agreed: Bool) async throws {
        if Self.stubbed { return }
        let _: PortalJSON.Empty = try await client.patch("api/extensions/requests",
                                                         body: MemberDecision(requestId: requestId, agreed: agreed))
    }

    /// A producer approves (setting the terms when first) or denies with a reason.
    func decideAsProducer(_ decision: ProducerDecision) async throws {
        if Self.stubbed { return }
        let _: PortalJSON.Empty = try await client.patch("api/extensions/requests", body: decision)
    }

    static var stubbed: Bool {
        SampleMode.isOn
    }
}

// MARK: Request bodies (`app/api/extensions/requests/route.ts`)

struct NewExtensionRequest: Encodable, Equatable {
    let cycleNumber: Int
    let requestedDays: Double
    let reason: String
}

struct MemberDecision: Encodable, Equatable {
    var kind = "member"
    let requestId: String
    let agreed: Bool
}

struct ProducerDecision: Encodable, Equatable {
    var kind = "producer"
    let requestId: String
    let approved: Bool
    /// Only the first approving producer sets the terms; later approvals send none.
    var grantedDays: Double?
    var grantedUserIds: [String]?
    /// Required when denying.
    var reason: String?
}
