import Foundation

/// `GET api/app/home`: the Portal dashboard as JSON (Up next, activity, the
/// student grade snapshot, and the workspaces this person can see).
struct HomePayload: Decodable, Sendable {
    let upNext: UpNext?
    let activity: [ActivityEntry]
    let snapshot: GradeSnapshot?
    let workspaces: [WorkspaceSummary]
}

/// The signed-in member's package this cycle.
struct UpNext: Decodable, Sendable, Hashable {
    let cycleNumber: Int
    let groupTopic: String?
    let finalCutDate: Date?
    let producerName: String?
    let memberNames: [String]
    let checkInsDone: Int
    let checkInsTotal: Int
    let stages: [DueStage]

    /// The first stage not done yet, which is what's due next.
    var nextStage: DueStage? { stages.first { !$0.done } }
}

/// One check-in with its due date (`proofOfContact`, `aRollBRoll`, `initialCut`, `finalCut`).
struct DueStage: Decodable, Sendable, Hashable, Identifiable {
    let key: String
    let label: String
    let done: Bool
    let dueDate: Date?

    var id: String { key }

    /// The student screen for this check-in.
    var studentStage: StudentStage? {
        switch key {
        case "proofOfContact": .brainstorming
        case "aRollBRoll": .aRoll
        case "initialCut": .initialCut
        case "finalCut": .finalCut
        default: nil
        }
    }

    /// When it closes: 11:59 PM Pacific on its date (Portal `src/lib/deadlines.ts`).
    var closesAt: Date? { dueDate.map(Deadline.close(onDayOf:)) }
}

struct ActivityEntry: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let actorName: String?
    let initials: String
    let verb: String
    let subject: String?
    let createdAt: Date
}

/// Students' grade snapshot (EPs and up have none).
struct GradeSnapshot: Decodable, Sendable, Hashable {
    struct Score: Decodable, Sendable, Hashable { let earned: Double; let possible: Double }

    let letter: String?
    let percentage: Double?
    let packages: Score
    let participation: Score
    let livestreamHours: Double
    let requiredLivestreamHours: Double
    let semesterLabel: String
    let extensionsRemaining: Double
    let extensionBank: Double
    let unreadFeedback: Int
}

struct WorkspaceSummary: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let projects: [ProjectSummary]
}

struct ProjectSummary: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let updatedAt: Date
    let mediaCount: Int
}

/// Cycle deadlines close at 11:59 PM Pacific on their date. The Portal stores
/// the date as midnight UTC, so the calendar day is read in UTC.
enum Deadline {
    static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    static func close(onDayOf stored: Date) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.dateComponents([.year, .month, .day], from: stored)
        var pacificCalendar = Calendar(identifier: .gregorian)
        pacificCalendar.timeZone = pacific
        let parts = DateComponents(year: day.year, month: day.month, day: day.day, hour: 23, minute: 59)
        return pacificCalendar.date(from: parts) ?? stored
    }

    /// "2d 4h", "5h 12m", "12m", or nil once it has passed.
    static func remaining(until close: Date, now: Date = Date()) -> String? {
        let seconds = Int(close.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }
}
