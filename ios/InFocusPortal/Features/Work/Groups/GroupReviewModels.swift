import Foundation

/// The producer-only parts of `GET api/package-cycle/stage?stage=…&rowId=…` that the
/// student `StageView` leaves out: Final Cut grading, Package of the Cycle and the toss.
struct GroupStageExtras: Decodable, Sendable, Hashable {
    struct Row: Decodable, Sendable, Hashable {
        let packageOfCycleAt: Date?
    }

    let canGradeFinalCut: Bool?
    let finalCutGrade: FinalCutGrade?
    let packageOfCycle: PackageOfCyclePanel?
    let canEditToss: Bool?
    let row: Row?

    static let none = GroupStageExtras(canGradeFinalCut: nil, finalCutGrade: nil, packageOfCycle: nil, canEditToss: nil, row: nil)
}

/// One stage view and its producer extras, from a single request.
struct GroupStageBundle: Sendable {
    let view: StageView
    let extras: GroupStageExtras
}

/// Member grades on a Final Cut (`loadFinalCutGradePanel`). Executive producers score each
/// member (quality and effort out of 25); the official grade averages them, then any revision
/// cap and the late deduction.
struct FinalCutGrade: Decodable, Sendable, Hashable {
    struct Grader: Decodable, Sendable, Hashable, Identifiable {
        let userId: String
        let name: String?
        let email: String?
        let required: Bool
        let scoredCount: Int

        var id: String { userId }
        var label: String { name?.isEmpty == false ? name! : email ?? "Executive producer" }
    }

    let canGrade: Bool
    let complete: Bool
    let viewerUserId: String
    let deadlineAt: Date?
    let turnedInAt: Date?
    let extensionDays: Double
    let daysLate: Double
    let penaltyMultiplier: Double
    let blocksSecondRevision: Bool
    let secondRevisionEligible: Bool
    let feedback: String
    let published: Bool
    let publishedAt: Date?
    let members: [FinalCutMemberGrade]
    let graders: [Grader]

    /// Members this grader can still score (a member at 75% or more before a revision is locked).
    var scoringMembers: Int { members.filter { !$0.locked }.count }
}

struct FinalCutMemberGrade: Decodable, Sendable, Hashable, Identifiable {
    struct GraderScore: Decodable, Sendable, Hashable, Identifiable {
        let userId: String
        let name: String
        let required: Bool
        let quality: Double?
        let effort: Double?

        var id: String { userId }
        var scored: Bool { quality != nil && effort != nil }
    }

    let userId: String
    let name: String?
    let email: String?
    let myQuality: Double?
    let myEffort: Double?
    let locked: Bool
    let complete: Bool
    let pendingCount: Int
    let qualityAverage: Double?
    let effortAverage: Double?
    let average: Double?
    let afterRevisionCap: Double?
    let revisionCapped: Bool
    let officialPoints: Double?
    let revisionCount: Int
    let secondRevisionEligible: Bool
    let daysLate: Double
    /// The penalty that applies: the executive's override when set, otherwise the automatic one.
    let penaltyMultiplier: Double
    let automaticPenaltyMultiplier: Double
    /// An executive's override (5/10/15/20/30); nil means automatic.
    let latePenaltyPercent: Int?
    let graderScores: [GraderScore]

    var id: String { userId }
    var label: String { name?.isEmpty == false ? name! : email ?? "Member" }
}

/// `POST api/package-cycle/grade`'s answer.
struct FinalCutScoreResult: Decodable, Sendable, Hashable {
    let savedCount: Int
    let gradedCount: Int
    let complete: Bool
}

/// One member's scores as `POST api/package-cycle/grade` takes them.
struct FinalCutScoreInput: Encodable, Sendable, Hashable {
    let memberUserId: String
    let qualityPoints: Double
    let effortPoints: Double
}

/// Package of the Cycle voting beside Final Cut grading. Unanimous executives win it.
struct PackageOfCyclePanel: Decodable, Sendable, Hashable {
    struct Vote: Decodable, Sendable, Hashable, Identifiable {
        let userId: String
        let name: String
        let voted: Bool
        var id: String { userId }
    }

    let canVote: Bool
    let myVote: Bool
    let awardedAt: Date?
    let blockedReason: String?
    let graders: [Vote]

    var votes: Int { graders.filter(\.voted).count }
    /// A blocked reason stops new votes only; withdrawing is always allowed.
    var voteBlocked: Bool { !myVote && blockedReason != nil }
}

/// A note on a group stage (`api/package-cycle/comments`), with the parts the producer
/// thread needs: resolved state, the review link a "submitted a review" notice carries,
/// and the clip a note was left on (`[[clip:<mediaId>]]`).
struct GroupNote: Decodable, Sendable, Hashable, Identifiable {
    struct Author: Decodable, Sendable, Hashable {
        let userId: String
        let name: String?
        let email: String?
    }

    let id: String
    let body: String
    let createdAt: Date
    let resolvedAt: Date?
    let reviewHref: String?
    let author: Author

    var authorName: String { author.name?.isEmpty == false ? author.name! : author.email ?? "Producer" }
    var clipId: String? { GroupNote.parseClip(body).clipId }
    var text: String { GroupNote.parseClip(body).text }

    static func wrapClip(_ mediaId: String, _ body: String) -> String { "[[clip:\(mediaId)]]\n\(body)" }

    /// The Portal's `parseClipComment`.
    static func parseClip(_ body: String) -> (clipId: String?, text: String) {
        guard body.hasPrefix("[[clip:"), let end = body.range(of: "]]") else { return (nil, body) }
        let id = String(body[body.index(body.startIndex, offsetBy: 7)..<end.lowerBound])
        guard !id.isEmpty, !id.contains("]") else { return (nil, body) }
        var rest = body[end.upperBound...]
        if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        return (id, String(rest))
    }
}

struct GroupNotes: Decodable, Sendable {
    let comments: [GroupNote]
    let unread: Int?
}

/// Producer notes on a group (`api/package-progress/<rowId>/notes`), shared with Package Cycle.
struct GroupRosterNotes: Codable, Sendable, Hashable {
    let possibleIdeas: String?
}

/// An Initial Cut decision (`POST api/package-progress/<rowId>/approval`).
enum CutAction: Sendable, Hashable {
    case approve(note: String, versionId: String?)
    case needsRevisions(versionId: String?)
    case unapprove
    case approveAnyway
}
