import Foundation

/// The Equipment endpoints, or stub data for DEBUG screenshots (`FeatureStub`).
struct EquipmentService: Sendable {
    var access: @Sendable () async throws -> EquipmentAccess
    var mine: @Sendable () async throws -> MyEquipment
    var available: @Sendable () async throws -> [GearItem]
    var request: @Sendable (_ body: GearRequestBody) async throws -> Void
    var managedRequests: @Sendable () async throws -> [ManagedRequests.Request]
    var decide: @Sendable (_ requestId: String, _ approve: Bool) async throws -> Void
    var out: @Sendable () async throws -> [ManagedOut.Item]
    /// `force-return` an item that's out, or `release-hold` one that's held.
    var outAction: @Sendable (_ itemId: String, _ action: String) async throws -> Void

    static func live(_ client: PortalClient) -> EquipmentService {
        EquipmentService(
            access: { try await client.get("api/equipment/me") },
            mine: { try await client.get("api/equipment/mine") },
            available: { try await client.get("api/equipment/public/items", as: AvailableGear.self).items },
            request: { body in try await client.post("api/equipment/public/requests", body: body) },
            managedRequests: { try await client.get("api/equipment/manage/requests", as: ManagedRequests.self).requests },
            decide: { id, approve in
                try await client.post("api/equipment/manage/requests",
                                      body: ManageDecision(id: id, action: approve ? "approve" : "deny"))
            },
            out: { try await client.get("api/equipment/manage/out", as: ManagedOut.self).items },
            outAction: { id, action in
                _ = try await client.send("PATCH", "api/equipment/manage/out",
                                          body: try PortalJSON.encoder().encode(OutAction(action: action, itemId: id)))
            }
        )
    }

    static func resolve(_ client: PortalClient) -> EquipmentService {
        #if DEBUG
        if FeatureStub.isOn { return .stub }
        #endif
        return .live(client)
    }
}

extension PortalError {
    /// Gear request answers, in words a student can act on.
    static func gearRequestMessage(_ error: Error) -> String {
        switch error as? PortalError {
        case .notFound?: "That student ID didn't match a Paly student, or an item was removed. Check your ID and try again."
        case .server(409, _)?: "Someone just took one of those items. Refresh the list and pick again."
        default: Loadable<GearItem>.message(for: error)
        }
    }
}
