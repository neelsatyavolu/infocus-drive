import Foundation

/// A cycle stage's status, as the Portal's `CycleStageStatus` (src/lib/package-stage-status.ts).
enum StageStatus: String, Decodable, Sendable, Hashable {
    case approved
    case stage1Approved = "stage-1-approved"
    case submitted, queued
    case needsRevisions = "needs-revisions"
    case stage2 = "stage-2", stage3 = "stage-3"
    case pending, locked, unknown

    init(from decoder: Decoder) throws {
        self = StageStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    var label: String {
        switch self {
        case .approved: "Approved"
        case .stage1Approved: "Approved in Stage 1"
        case .submitted: "Submitted"
        case .queued: "Queued"
        case .needsRevisions: "Revisions"
        case .stage2: "Stage 2"
        case .stage3: "Stage 3"
        case .pending: "Pending"
        case .locked: "Locked"
        case .unknown: "—"
        }
    }

    var tone: StatusTag.Tone {
        switch self {
        case .approved, .stage1Approved, .queued: .success
        case .submitted, .stage2, .stage3: .warning
        case .needsRevisions: .danger
        case .pending, .locked, .unknown: .neutral
        }
    }
}

/// `GET api/package-cycle/stage` (no stage): the student's cycle overview.
struct StudentGates: Decodable, Sendable, Hashable {
    let cycleNumber: Int
    let hasRow: Bool
    let unlocked: [String: Bool]
    let statuses: [String: StageStatus]
    let unread: [String: Int]

    func status(_ stage: StudentStage) -> StageStatus? { statuses[stage.rawValue] }

    /// Information and brainstorming are always open; the rest unlock in order.
    func isUnlocked(_ stage: StudentStage) -> Bool {
        switch stage {
        case .information, .brainstorming: true
        default: unlocked[stage.rawValue] ?? false
        }
    }
}

/// A person on a package, as the Portal labels them (display name + email).
struct PackagePerson: Decodable, Sendable, Hashable {
    let userId: String?
    let name: String?
    let email: String?

    var displayName: String { name?.isEmpty == false ? name! : email?.split(separator: "@").first.map(String.init) ?? "Member" }
}

/// `GET api/package-cycle/stage?stage=…`: one cycle stage of one package.
struct StageView: Decodable, Sendable {
    let empty: Bool
    let slug: String
    let isProducer: Bool
    let unlocked: Bool?
    let canUpload: Bool
    let canComment: Bool
    let canApproveAroll: Bool?
    let allowSecondFinalCut: Bool?
    let cutApproval: CutApproval?
    let row: StageRow?
    let media: [StageMedia]?
}

struct StageRow: Decodable, Sendable, Hashable {
    let id: String
    let cycleNumber: Int
    let groupTopic: String
    let headline: String?
    let toss: String?
    let proofOfContact: Bool
    let aRollBRoll: Bool
    let aRollNeedsChanges: Bool
    let initialCut: Bool
    let finalCut: Bool
    let awaitingRevisedInitialCut: Bool
    let initialCutNeedsRevisions: Bool
    let queuedForAirAt: Date?
    let approvalStage: String
    let remainingExecutiveSignoffs: Int?
    let assignedProducer: PackagePerson?
    let members: [PackagePerson]

    var memberNames: String { members.map(\.displayName).joined(separator: ", ") }
}

/// A clip or cut on a stage. Playback and poster URLs are signed and expire, so reload before playing again later.
struct StageMedia: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let rollKind: String?
    let projectId: String?
    let versionId: String?
    let versionNumber: Int
    let status: String
    let approvalStatus: String?
    let approvedInStage: Int?
    let thumbnailUrl: URL?
    let playbackUrl: URL?
    let commentCount: Int
    let isNew: Bool?

    var isReady: Bool { status == "READY" }
    var rollLabel: String? {
        switch rollKind {
        case "a-roll": "A-roll"
        case "b-roll": "B-roll"
        default: nil
        }
    }
}

/// The Initial Cut approval chain for this producer (`loadApprovalView`).
struct CutApproval: Decodable, Sendable, Hashable {
    let stage: String
    let canAct: Bool
    let canUnapprove: Bool
    let canApproveAnyway: Bool
    let awaitingRevisedInitialCut: Bool
    let remainingExecutiveSignoffs: Int?
}

/// A comment on a package stage (`api/package-cycle/comments`).
struct StageComment: Decodable, Sendable, Hashable, Identifiable {
    struct Author: Decodable, Sendable, Hashable { let userId: String; let name: String?; let email: String? }

    let id: String
    let body: String
    let createdAt: Date
    let author: Author

    var authorName: String { author.name ?? author.email?.split(separator: "@").first.map(String.init) ?? "Someone" }
}

struct StageComments: Decodable, Sendable {
    let comments: [StageComment]
    let unread: Int
}

/// `POST api/package-cycle/upload { action: "init" }`: where the file goes on InFocus Drive.
struct StageUploadTicket: Decodable, Sendable {
    let mediaId: String
    let versionId: String
    let upload: DriveUploadSession
}

/// An InFocus Drive upload session (Portal `NasUploadFields`).
struct DriveUploadSession: Decodable, Sendable, Hashable {
    let provider: String?
    let uploadUrl: URL
    let path: String?
    let token: String?
}
