import Foundation

/// One catch for the leaderboard (`CatchInput`, src/lib/thanksgiving-guard.ts).
struct HarvestCatch: Encodable, Equatable, Sendable {
    let kind: HarvestKind
    /// When it was caught (epoch ms, this device's clock).
    let at: Int64
    /// How long the visitor had been on screen (ms); nil for giant turkeys.
    let age: Int64?

    // `age` is required by the Portal's schema, so a giant turkey sends `"age": null`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(at, forKey: .at)
        try container.encode(age, forKey: .age)
    }

    enum CodingKeys: String, CodingKey { case kind, at, age }
}

/// `POST api/thanksgiving`: a batch of catches, the device's clock when sent, and never automation.
struct HarvestBatch: Encodable, Equatable, Sendable {
    let catches: [HarvestCatch]
    let sentAt: Int64
    var automation = false
}

/// The leaderboard's Portal calls. DEBUG stub sessions read a fictional board and send nowhere;
/// the App Review sample account never gets here (its row is hidden and the screen says no).
struct HarvestAPI: Sendable {
    var board: @Sendable () async throws -> HarvestBoard
    var send: @Sendable (HarvestBatch) async throws -> Void

    static func live(_ client: PortalClient) -> HarvestAPI {
        HarvestAPI(board: { try await client.get("api/thanksgiving") },
                   send: { batch in try await client.post("api/thanksgiving", body: batch) })
    }

    static func current(_ client: PortalClient) -> HarvestAPI {
        SampleMode.isOn ? .stub : .live(client)
    }

    /// Fictional people only.
    static let stub = HarvestAPI(
        board: {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return HarvestBoard.sample
        },
        send: { _ in }
    )
}

extension HarvestBoard {
    static let sample = HarvestBoard(
        year: 2026,
        rows: [
            HarvestEntry(userId: "stub-sage", name: "Sage", leaves: 61, pies: 12, wishbones: 1, giantTurkeys: 2, pardons: 4,
                         total: 80, rank: 1),
            HarvestEntry(userId: "stub-abby", name: "Abby", leaves: 40, pies: 9, wishbones: 0, giantTurkeys: 1, pardons: 2,
                         total: 52, rank: 2)
        ],
        disqualified: [
            HarvestEntry(userId: "stub-otto", name: "Otto", leaves: 900, pies: 0, wishbones: 0, giantTurkeys: 0, pardons: 0,
                         total: 900, rank: nil)
        ],
        viewerId: "stub-abby",
        contest: Contest(closesAt: Date(timeIntervalSince1970: 1_793_951_999), prizeDays: 2, result: nil)
    )
}
