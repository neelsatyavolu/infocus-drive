import Foundation

/// The Community feature's Portal calls. The App Review sample app (`SampleMode`) reads fictional
/// fixtures instead (and so do DEBUG screenshots).
struct CommunityAPI: Sendable {
    var classBoardCycle: @Sendable () async throws -> ClassBoardCycleSetting
    var setClassBoardCycle: @Sendable (_ cycleNumber: Int?) async throws -> ClassBoardCycleSaved
    var classBoardPin: @Sendable () async throws -> ClassBoardPin
    var newClassBoardPin: @Sendable () async throws -> ClassBoardPin

    static func live(_ client: PortalClient) -> CommunityAPI {
        struct Cycle: Encodable {
            let cycleNumber: Int?

            // `{ "cycleNumber": null }` follows the current cycle; the key must be sent.
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(cycleNumber, forKey: .cycleNumber)
            }

            enum CodingKeys: String, CodingKey { case cycleNumber }
        }
        return CommunityAPI(
            classBoardCycle: { try await client.get("api/platform/class-board-cycle") },
            setClassBoardCycle: { number in
                try await client.post("api/platform/class-board-cycle", body: Cycle(cycleNumber: number))
            },
            classBoardPin: { try await client.get("api/class-board/pin") },
            newClassBoardPin: { try await client.post("api/class-board/pin", body: PortalJSON.EmptyBody()) }
        )
    }

    /// Live, or the fictional fixtures in the sample app (`SampleMode`).
    static func current(_ client: PortalClient) -> CommunityAPI {
        if SampleMode.isOn { return .stub }
        return .live(client)
    }

    /// Fictional settings. No real people or PINs.
    static let stub = CommunityAPI(
        classBoardCycle: {
            ClassBoardCycleSetting(cycleNumber: nil, cycles: [.init(cycleNumber: 1, focus: "Profiles"),
                                                              .init(cycleNumber: 2, focus: "Campus news")],
                                   canEdit: true)
        },
        setClassBoardCycle: { number in
            SampleMode.notSaved()
            return ClassBoardCycleSaved(cycleNumber: number)
        },
        classBoardPin: { ClassBoardPin(pin: "000000") },
        newClassBoardPin: {
            SampleMode.notSaved()
            return ClassBoardPin(pin: "000000")
        }
    )
}
