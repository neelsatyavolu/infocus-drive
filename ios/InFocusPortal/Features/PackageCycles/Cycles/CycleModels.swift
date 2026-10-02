import Foundation

/// `GET api/package-cycles` (everyone): the semester's cycles and their stage dates.
struct CyclesPayload: Decodable, Sendable {
    /// Any producer (associate and up) can change dates.
    let canEdit: Bool
    /// Only executives, the adviser and the super admin can change how many cycles there are.
    let canEditCycleCount: Bool
    let cyclesPerSemester: Int
    let cycles: [CycleDates]
}

/// One cycle's focus and stage dates (`YYYY-MM-DD` keys, nil while TBD). Also the save body.
struct CycleDates: Codable, Hashable, Sendable, Identifiable {
    var cycleNumber: Int
    var focus: String?
    var pitchingDate: String?
    var proofOfContactDate: String?
    var aRollBRollDate: String?
    var initialCutDate: String?
    var finalCutDate: String?

    var id: Int { cycleNumber }

    func date(_ stage: RosterStage) -> String? {
        switch stage {
        case .pitching: pitchingDate
        case .proofOfContact: proofOfContactDate
        case .aRollBRoll: aRollBRollDate
        case .initialCut: initialCutDate
        case .finalCut: finalCutDate
        }
    }

    mutating func setDate(_ stage: RosterStage, _ value: String?) {
        switch stage {
        case .pitching: pitchingDate = value
        case .proofOfContact: proofOfContactDate = value
        case .aRollBRoll: aRollBRollDate = value
        case .initialCut: initialCutDate = value
        case .finalCut: finalCutDate = value
        }
    }

    func encode(to encoder: Encoder) throws {
        // nil dates are sent as null: that's how a date is cleared.
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cycleNumber, forKey: .cycleNumber)
        try container.encode(focus ?? "", forKey: .focus)
        try container.encode(pitchingDate, forKey: .pitchingDate)
        try container.encode(proofOfContactDate, forKey: .proofOfContactDate)
        try container.encode(aRollBRollDate, forKey: .aRollBRollDate)
        try container.encode(initialCutDate, forKey: .initialCutDate)
        try container.encode(finalCutDate, forKey: .finalCutDate)
    }
}

/// `GET api/package-cycle/package-of-cycle`: every Package of the Cycle, newest cycle first.
struct WinnersPayload: Decodable, Sendable {
    let viewerUserId: String
    /// Producers download any winner's certificate; members only their own.
    let canDownloadAll: Bool
    let winners: [CycleWinner]
}

struct CycleWinner: Decodable, Hashable, Sendable, Identifiable {
    struct Member: Decodable, Hashable, Sendable, Identifiable {
        let userId: String
        let name: String
        var id: String { userId }
    }

    let rowId: String
    let cycleNumber: Int
    let topic: String
    let headline: String?
    let awardedAt: Date
    let members: [Member]
    var id: String { rowId }

    var title: String { headline?.trimmingCharacters(in: .whitespaces).rosterNonEmpty ?? topic }
}
