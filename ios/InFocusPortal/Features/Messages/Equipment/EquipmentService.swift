import Foundation

/// The Equipment endpoints, or fictional data in the sample app (`SampleMode`).
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
    /// Inventory: every item not archived.
    var inventory: @Sendable () async throws -> [ManagedOut.Item]
    var addItem: @Sendable (_ body: NewGearBody) async throws -> Void
    /// Rename or recode an item, or archive it (`archived: true`).
    var updateItem: @Sendable (_ body: GearPatchBody) async throws -> Void
    var managers: @Sendable () async throws -> [ManagerRow]
    /// Producers only: everyone on the Portal, to appoint from.
    var members: @Sendable () async throws -> [PortalMember]
    var addManager: @Sendable (_ userId: String) async throws -> Void
    var removeManager: @Sendable (_ userId: String) async throws -> Void

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
            },
            inventory: { try await client.get("api/equipment/manage/items", as: ManagedOut.self).items },
            addItem: { body in try await client.post("api/equipment/manage/items", body: body) },
            updateItem: { body in
                _ = try await client.send("PATCH", "api/equipment/manage/items", body: try PortalJSON.encoder().encode(body))
            },
            managers: { try await client.get("api/equipment/manage/managers", as: ManagerList.self).managers },
            members: { try await client.get("api/platform/users") },
            addManager: { id in try await client.post("api/equipment/manage/managers", body: ManagerBody(userId: id)) },
            removeManager: { id in
                try await client.delete("api/equipment/manage/managers", query: [URLQueryItem(name: "userId", value: id)])
            }
        )
    }

    static func resolve(_ client: PortalClient) -> EquipmentService {
        if FeatureStub.isOn { return .stub }
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

    /// Inventory answers: a 409 is a code in use, or an item that's out or held.
    static func inventoryMessage(_ error: Error, archiving: Bool) -> String {
        switch error as? PortalError {
        case .server(409, _)?:
            archiving ? "Only items that are in can be archived. Return it or release its hold first."
                : "Another item already uses that code."
        default: Loadable<GearItem>.message(for: error)
        }
    }
}
