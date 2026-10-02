import Foundation

// The Grade Editor's data, decoded exactly as `GET/POST api/grades/admin` sends it
// (`app/api/grades/admin/route.ts`). Scores are the Portal's; nothing is recomputed here.

/// A graded cell that can also be "not graded yet" or "exempt" (`GradeScoreState`).
enum ScoreState: String, Codable, Equatable, Sendable {
    case ungraded = "UNGRADED"
    case exempt = "EXEMPT"
}

/// A check-in cell: points out of 5, or a state.
enum CheckInValue: Equatable, Sendable, Decodable {
    case points(Int)
    case state(ScoreState)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let points = try? container.decode(Int.self) {
            self = .points(points)
        } else {
            self = .state(try container.decode(ScoreState.self))
        }
    }

    var label: String {
        switch self {
        case .points(let points): "\(points)/5"
        case .state(.exempt): "Exempt"
        case .state(.ungraded): "—"
        }
    }
}

/// The four check-ins, in order, with the web's labels.
enum CheckInStage: String, CaseIterable, Identifiable, Codable, Sendable {
    case pitching, proofOfContact, aRollBRoll, initialCut

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pitching: "Pitching"
        case .proofOfContact: "PoC"
        case .aRollBRoll: "A-roll/B-roll"
        case .initialCut: "Initial Cut"
        }
    }
}

/// One cycle's check-ins. A nil cell has not been released (not due yet, or not
/// on this person's package), so it can't be edited.
struct CheckInScores: Decodable, Equatable, Sendable {
    var values: [CheckInStage: CheckInValue?]

    init(_ values: [CheckInStage: CheckInValue?] = [:]) { self.values = values }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: GradeEditorKey.self)
        var values: [CheckInStage: CheckInValue?] = [:]
        for stage in CheckInStage.allCases {
            values[stage] = try container.decodeIfPresent(CheckInValue.self, forKey: GradeEditorKey(stage.rawValue))
        }
        self.values = values
    }

    subscript(stage: CheckInStage) -> CheckInValue? { values[stage] ?? nil }
}

struct GradeEditorKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct GradeCycle: Decodable, Equatable, Identifiable, Sendable {
    let cycleNumber: Int
    let focus: String?
    var finalCutDate: String?
    var id: Int { cycleNumber }

    var title: String {
        if let focus, !focus.trimmingCharacters(in: .whitespaces).isEmpty { return "Cycle \(cycleNumber): \(focus)" }
        return "Cycle \(cycleNumber)"
    }
}

struct ExtensionDetails: Decodable, Equatable, Sendable {
    let calculatedDays: Double
    let freeDays: Double
    let chargedDays: Double
    let exempt: Bool
}

/// One person's row in the cycle view (and the body of every POST answer).
struct CycleGradeRow: Decodable, Equatable, Identifiable, Sendable {
    let userId: String
    var name: String?
    var email: String?
    var checkInScores: CheckInScores?
    var checkInOverrides: CheckInScores?
    var finalCutState: ScoreState?
    /// The awarded Final Cut points out of 50 (after any late penalty).
    var effortPoints: Double?
    var totalPoints: Double?
    var percentage: Double?
    var revised: Bool
    var feedback: String
    /// `YYYY-MM-DD`.
    var turnedInDate: String?
    var freeExtensionDays: Double
    var extensionDetails: ExtensionDetails?
    var published: Bool
    var publishedAt: Date?
    var extensionsRemaining: Double?

    var id: String { userId }
    var displayName: String { GradeEditorText.name(name, email: email) }
}

struct CycleAverage: Decodable, Equatable, Sendable {
    let cycleNumber: Int
    let averageTotal: Double?
    let averagePercentage: Double?
    let publishedCount: Int
}

/// `GET api/grades/admin?cycle=N`.
struct CycleGrades: Decodable, Equatable, Sendable {
    let activeCycleNumber: Int
    let cycles: [GradeCycle]
    let activeCycleAverage: CycleAverage?
    var rows: [CycleGradeRow]

    var activeCycle: GradeCycle? { cycles.first { $0.cycleNumber == activeCycleNumber } }
}

/// `GET api/grades/admin?view=totals`: official credits per person (DESIGN: nil shows "—").
struct GradeTotals: Decodable, Equatable, Sendable {
    struct CycleTotal: Decodable, Equatable, Sendable {
        let cycleNumber: Int
        let finalCutState: ScoreState?
        let totalPoints: Double?
    }

    struct Row: Decodable, Equatable, Identifiable, Sendable {
        let userId: String
        let name: String?
        let email: String?
        var notes: String
        let participationEarned: Double
        let participationPossible: Double
        let checkInPoints: Double?
        let checkInPossible: Double?
        let livestreamPoints: Double?
        let livestreamHours: Double
        let portfolioPoints: Double?
        let cycleTotals: [CycleTotal]

        var id: String { userId }
        var displayName: String { GradeEditorText.name(name, email: email) }
    }

    let cycles: [GradeCycle]
    var totalsRows: [Row]
}

/// `GET api/grades/admin?view=missing`.
struct MissingGrades: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case notEntered = "not_entered"
        case unpublished
    }

    struct Entry: Decodable, Equatable, Sendable {
        let cycleNumber: Int
        let status: Status
    }

    struct Person: Decodable, Equatable, Identifiable, Sendable {
        let userId: String
        let name: String?
        let email: String?
        let missing: [Entry]
        var id: String { userId }
        var displayName: String { GradeEditorText.name(name, email: email) }
    }

    let cycles: [GradeCycle]
    let consideredCycleNumbers: [Int]
    let missingReport: [Person]
}

enum GradeEditorText {
    /// A person's name, else their email, else "Student".
    static func name(_ name: String?, email: String?) -> String {
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if let email, !email.isEmpty { return email }
        return "Student"
    }
}
