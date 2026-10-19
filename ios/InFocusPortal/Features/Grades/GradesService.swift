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

    /// Execs: the package groups of one cycle, for the grant form.
    func grantGroups(cycle: Int) async throws -> [GrantGroup] {
        if Self.stubbed { return try GradesFixtures.decode(GrantGroups.self, GradesFixtures.grantGroupsJSON).groups }
        let payload: GrantGroups = try await client.get("api/extensions/grants",
                                                        query: [URLQueryItem(name: "cycleNumber", value: String(cycle))])
        return payload.groups
    }

    /// Execs grant an extension directly; it counts as the first approval.
    func grant(_ grant: NewExtensionGrant) async throws {
        if Self.stubbed { return }
        let _: PortalJSON.Empty = try await client.post("api/extensions/grants", body: grant)
    }

    /// Execs (re)send the decision email for a decided request; answers how many were emailed.
    func emailGroup(requestId: String) async throws -> Int {
        if Self.stubbed { return 2 }
        struct Body: Encodable { let requestId: String }
        struct Result: Decodable { let sent: Int? }
        let result: Result = try await client.post("api/extensions/requests/notify", body: Body(requestId: requestId))
        return result.sent ?? 0
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
    /// An exec grants a pending request before every member agrees (only ever `true`).
    var grantWithoutAgreement: Bool?
    /// Required when denying.
    var reason: String?
}

// MARK: Exec grants (`app/api/extensions/grants/route.ts`)

struct GrantGroups: Decodable, Hashable, Sendable {
    let groups: [GrantGroup]
}

struct GrantGroup: Decodable, Hashable, Sendable, Identifiable {
    struct Member: Decodable, Hashable, Sendable {
        let userId: String
        let name: String?
        let email: String?

        var label: String { name ?? email ?? "Unknown" }
    }

    let id: String
    let groupTopic: String
    let members: [Member]

    /// "Lunch line wait times · Abby, Otto" (topic first, like the web).
    var label: String {
        let names = members.map(\.label).joined(separator: ", ")
        return groupTopic.isEmpty ? names : "\(groupTopic) · \(names)"
    }
}

struct NewExtensionGrant: Encodable, Equatable {
    let progressRowId: String
    let days: Double
    let grantedUserIds: [String]
    let reason: String
}
