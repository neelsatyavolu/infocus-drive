import Foundation

/// The status pill on a Groups tile: a port of the Portal's `groupTileStatus`
/// (src/lib/group-tile-status.ts) so the app and the website say the same thing.
struct GroupTileStatus: Equatable {
    let label: String
    let tone: StatusTag.Tone

    static func of(_ row: GroupRow, now: Date = Date()) -> GroupTileStatus {
        func pendingReview(_ submittedAt: Date?, _ label: String) -> GroupTileStatus {
            let suffix = submittedAt.map { " for \(max(0, Int(now.timeIntervalSince($0) / 3_600)))h" } ?? ""
            return GroupTileStatus(label: "\(label) Pending Review\(suffix)", tone: .warning)
        }

        if !row.pitching { return GroupTileStatus(label: "Pitch Pending", tone: .neutral) }

        if !row.proofOfContact {
            if row.proofs.count >= BrainstormPackage.proofSlots.count, GoogleDocLink.isValid(row.brainstormDocUrl ?? "") {
                return pendingReview(row.reviewReadyAt?.brainstorming, "Brainstorm")
            }
            return GroupTileStatus(label: "Brainstorming", tone: .neutral)
        }

        if !row.aRollBRoll {
            if row.aRollNeedsChanges == true && row.aRollHasMedia {
                return GroupTileStatus(label: "A-roll/B-roll Needs Revisions", tone: .danger)
            }
            if row.aRollHasMedia { return pendingReview(row.reviewReadyAt?.aRoll, "A-roll/B-roll") }
            return GroupTileStatus(label: "A-roll/B-roll Pending", tone: .neutral)
        }

        if row.approvalStage != "APPROVED" {
            let version = cutTitle(row.initialCutVersionNumber)
            if row.initialCutMediaItemId == nil { return GroupTileStatus(label: "Initial Cut Pending", tone: .neutral) }
            if row.initialCutNeedsRevisions || row.approvalStage == "DRAFT" {
                return GroupTileStatus(label: "\(version) Needs Revisions", tone: .danger)
            }
            if row.awaitingRevisedInitialCut && row.approvalStage == "ASSOCIATE_REVIEW" {
                return GroupTileStatus(label: "Approved in Stage 1 · Awaiting revised upload", tone: .success)
            }
            if row.approvalStage == "ADVISER_REVIEW" {
                return GroupTileStatus(label: "Waiting for the adviser (Stage 2)", tone: .warning)
            }
            if row.approvalStage == "EXECUTIVE_REVIEW" {
                let left = row.remainingExecutiveSignoffs ?? 2
                return GroupTileStatus(label: left == 1 ? "1 exec left" : left > 0 ? "\(left) execs left" : "Waiting for exec approvals",
                                       tone: .warning)
            }
            return pendingReview(row.reviewReadyAt?.initialCut, version.replacingOccurrences(of: " Version ", with: " V"))
        }

        if row.finalCutGraded == true { return GroupTileStatus(label: "Final Cut Graded", tone: .success) }
        if row.queuedForAir { return GroupTileStatus(label: "Final Cut Queued", tone: .success) }
        if row.finalCutMediaItemId != nil { return GroupTileStatus(label: "Final Cut Submitted", tone: .warning) }
        return GroupTileStatus(label: "Final Cut Pending", tone: .neutral)
    }

    /// "Initial Cut Version 2", or "Initial Cut" before the first upload.
    static func cutTitle(_ versionNumber: Int?) -> String {
        guard let versionNumber, versionNumber > 0 else { return "Initial Cut" }
        return "Initial Cut Version \(versionNumber)"
    }
}

/// Which stage a group is on now: the Groups tile opens it.
enum GroupStage: String, CaseIterable, Hashable, Identifiable {
    case pitching, brainstorming
    case aRoll = "a-roll"
    case initialCut = "initial-cut"
    case finalCut = "final-cut"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pitching: "Pitch"
        case .brainstorming: "Brainstorming"
        case .aRoll: "A-roll/B-roll"
        case .initialCut: "Initial Cut"
        case .finalCut: "Final Cut"
        }
    }

    /// Group stage slugs on the website, including the three Initial Cut review stages.
    init?(slug: String) {
        if slug.hasPrefix("initial-stage-") { self = .initialCut; return }
        self.init(rawValue: slug)
    }

    static func current(for row: GroupRow) -> GroupStage {
        if !row.pitching { return .pitching }
        if !row.proofOfContact { return .brainstorming }
        if !row.aRollBRoll { return .aRoll }
        if row.approvalStage != "APPROVED" { return .initialCut }
        return .finalCut
    }

    func isDone(for row: GroupRow) -> Bool {
        switch self {
        case .pitching: row.pitching
        case .brainstorming: row.proofOfContact
        case .aRoll: row.aRollBRoll
        case .initialCut: row.approvalStage == "APPROVED"
        case .finalCut: row.queuedForAir || row.finalCutGraded == true
        }
    }
}

/// The Portal's Groups visibility (src/lib/groups-visibility.ts): associates see the
/// packages assigned to them (and unassigned ones); executives, the adviser and the
/// super admin see every package. "Yours" keeps assigned packages, plus Stage 2/3
/// and Final Cut work for executives, at the top.
enum GroupsVisibility {
    static func visible(_ rows: [GroupRow], for user: PortalUser) -> [GroupRow] {
        guard user.role == .associateProducer else { return rows }
        return rows.filter { row in
            row.assignedProducer == nil || row.assignedProducer?.email?.lowercased() == user.email.lowercased()
        }
    }

    static func isPrimary(_ row: GroupRow, for user: PortalUser) -> Bool {
        if row.isAssigned(toEmail: user.email) { return true }
        guard user.role == .executiveProducer || user.role == .superAdmin || user.role == .adviser else { return false }
        if row.queuedForAir && row.finalCutGraded == true { return false }
        if row.approvalStage == "EXECUTIVE_REVIEW" || row.approvalStage == "APPROVED" { return true }
        return user.role == .adviser && row.approvalStage == "ADVISER_REVIEW"
    }
}
