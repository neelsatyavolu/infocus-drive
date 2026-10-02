import Foundation

/// Every Portal call the Package Cycles area makes. In the sample app
/// (`SampleMode`) it answers from fictional, editable fixtures instead.
struct PackageCyclesService: Sendable {
    let client: PortalClient

    static func resolve(_ client: PortalClient) -> PackageCyclesService { PackageCyclesService(client: client) }

    // MARK: Roster (`/package-progress`, producers)

    func roster(cycle: Int?) async throws -> RosterPayload {
        if Self.stubbed { return try await PackageCyclesStub.shared.roster(cycle: cycle) }
        return try await client.get("api/package-progress",
                                    query: cycle.map { [URLQueryItem(name: "cycle", value: String($0))] } ?? [])
    }

    /// Saves every row of a cycle (the Portal replaces the cycle with exactly these rows).
    func saveRoster(cycle: Int, rows: [[String: JSONValue]]) async throws {
        if Self.stubbed { return await PackageCyclesStub.shared.save(cycle: cycle, rows: rows) }
        let _: PortalJSON.Empty = try await client.post("api/package-progress", body: RosterSave(cycleNumber: cycle, rows: rows))
    }

    /// Moves a group (members, uploads, comments, approvals) to another cycle.
    func move(rowId: String, to cycle: Int) async throws {
        if Self.stubbed { return await PackageCyclesStub.shared.move(rowId: rowId, to: cycle) }
        struct Body: Encodable { let cycleNumber: Int }
        let _: PortalJSON.Empty = try await client.post("api/package-progress/\(rowId)/move", body: Body(cycleNumber: cycle))
    }

    /// Everyone who can be added to a group.
    func people() async throws -> [RosterPerson] {
        if Self.stubbed { return PackageCyclesStub.people }
        return try await client.get("api/platform/users")
    }

    // MARK: Cycle dates (`/package-cycles`)

    func cycles() async throws -> CyclesPayload {
        if Self.stubbed { return await PackageCyclesStub.shared.cycles() }
        return try await client.get("api/package-cycles")
    }

    func saveCycle(_ cycle: CycleDates) async throws {
        if Self.stubbed { return await PackageCyclesStub.shared.saveCycle(cycle) }
        let _: PortalJSON.Empty = try await client.post("api/package-cycles", body: cycle)
    }

    /// How many cycles this semester has (executives, the adviser and the super admin).
    func setCyclesPerSemester(_ count: Int) async throws {
        if Self.stubbed { return await PackageCyclesStub.shared.setCount(count) }
        struct Body: Encodable { let cyclesPerSemester: Int }
        let _: PortalJSON.Empty = try await client.post("api/platform/program-settings", body: Body(cyclesPerSemester: count))
    }

    func winners() async throws -> WinnersPayload {
        if Self.stubbed { return PackageCyclesStub.winners }
        return try await client.get("api/package-cycle/package-of-cycle")
    }

    /// A winner's Package of the Cycle certificate (opens in the in-app Portal view).
    func certificateURL(rowId: String, memberId: String) -> URL {
        client.url("api/package-cycle/package-of-cycle/certificate",
                   query: [URLQueryItem(name: "rowId", value: rowId), URLQueryItem(name: "memberId", value: memberId)])
    }

    static var stubbed: Bool {
        SampleMode.isOn
    }
}
