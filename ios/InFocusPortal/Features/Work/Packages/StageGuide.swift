import Foundation

/// The words a student's stage pages show, ported from the Portal so the app and
/// the website always agree: the status tag (`stageStatusFor`), the next-step
/// sentence (`studentNextStep`), the Initial Cut approval path, upload rules and
/// version results (`components/package-stages/stage-status.ts`, `group-tile-status.ts`).
enum StageGuide {
    // MARK: Status

    /// The stage's status for a student (Final Cut shows Approved, never Queued).
    static func status(_ stage: StudentStage, view: StageView) -> StageStatus? {
        guard let row = view.row else { return nil }
        let hasMedia = !(view.media ?? []).isEmpty
        let unlocked = view.unlocked ?? true
        switch stage {
        case .information, .brainstorming:
            return nil
        case .aRoll:
            if !unlocked { return .locked }
            if row.aRollBRoll { return .approved }
            if row.aRollNeedsChanges && hasMedia { return .needsRevisions }
            return hasMedia ? .submitted : .pending
        case .initialCut:
            if !unlocked { return .locked }
            if row.initialCutNeedsRevisions { return .needsRevisions }
            if row.awaitingRevisedInitialCut && row.approvalStage == "ASSOCIATE_REVIEW" { return .stage1Approved }
            if row.approvalStage == "APPROVED" { return .approved }
            guard hasMedia else { return .pending }
            switch row.approvalStage {
            case "DRAFT": return .needsRevisions
            case "ADVISER_REVIEW": return .stage2
            case "EXECUTIVE_REVIEW": return .stage3
            default: return .submitted
            }
        case .finalCut:
            if !unlocked { return .locked }
            if row.queuedForAirAt != nil { return .approved }
            return hasMedia ? .submitted : .pending
        }
    }

    /// Tag words; Stage 3 says how many executive sign-offs are left.
    static func label(_ status: StageStatus, remainingExecutiveSignoffs: Int?) -> String {
        if status == .stage3, let remaining = remainingExecutiveSignoffs, let left = execsLeft(remaining) { return left }
        return status.label
    }

    static func execsLeft(_ remaining: Int) -> String? {
        guard remaining > 0 else { return nil }
        return remaining == 1 ? "1 exec left" : "\(remaining) execs left"
    }

    // MARK: Next step

    static func lockedSentence(_ stage: StudentStage) -> String {
        switch stage {
        case .aRoll: "Unlocks when Brainstorming is approved."
        case .initialCut: "Unlocks when A-roll/B-roll is approved."
        default: "Unlocks when your Initial Cut is approved."
        }
    }

    /// The one sentence saying what to do now (or that there's nothing to do yet).
    static func nextStep(_ stage: StudentStage, status: StageStatus?, hasFinalCut: Bool) -> String {
        if status == .locked { return lockedSentence(stage) }
        switch stage {
        case .aRoll:
            switch status {
            case .needsRevisions: return "Your producer asked for changes. Read the feedback, then upload new clips."
            case .submitted: return "Waiting for your producer to approve."
            case .approved: return "Approved. Uploads are closed unless your producer asks for changes."
            default: return "Upload your A-roll and B-roll clips for your producer to review."
            }
        case .initialCut:
            switch status {
            case .pending: return "Upload your Initial Cut. Your producer reviews it first."
            case .needsRevisions: return "Changes were requested. Read the feedback, then upload a new version."
            case .stage1Approved: return "Upload your revised version to move on to Stage 2."
            case .approved:
                return hasFinalCut
                    ? "Approved. Nothing more to do for this stage."
                    : "Approved for Final Cut. Next, upload your Final Cut with a headline and a toss for the anchors."
            default: return "Nothing to do until a reviewer asks for changes. Feedback shows up here."
            }
        default:
            switch status {
            case .submitted: return "Turned in. Your executive producers grade it next."
            case .approved: return "Approved. Nothing more to do for this stage."
            default: return "Upload your Final Cut with a headline and a toss for the anchors."
            }
        }
    }

    // MARK: Approval path

    struct ApprovalStep: Hashable, Identifiable {
        enum State: Hashable { case done, current, upcoming }
        let number: Int
        let label: String
        let state: State
        let stateLabel: String?
        let tone: StatusTag.Tone
        var id: Int { number }
    }

    private static let stepLabels = ["Producer review", "Adviser review", "Executive sign-off"]
    private static let currentIndex = ["DRAFT": 0, "ASSOCIATE_REVIEW": 0, "ADVISER_REVIEW": 1, "EXECUTIVE_REVIEW": 2, "APPROVED": 3]

    /// Stage 1 producer → Stage 2 adviser → Stage 3 executives. Before any cut every step is upcoming.
    static func approvalPath(_ row: StageRow, hasMedia: Bool) -> [ApprovalStep] {
        let current = hasMedia ? (currentIndex[row.approvalStage] ?? -1) : -1
        return stepLabels.enumerated().map { index, label in
            let number = index + 1
            if current < 0 || index > current {
                return ApprovalStep(number: number, label: label, state: .upcoming, stateLabel: nil, tone: .neutral)
            }
            if index < current {
                return ApprovalStep(number: number, label: label, state: .done, stateLabel: "Done", tone: .success)
            }
            if row.initialCutNeedsRevisions || row.approvalStage == "DRAFT" {
                return ApprovalStep(number: number, label: label, state: .current, stateLabel: "Needs revisions", tone: .danger)
            }
            if index == 0 && row.awaitingRevisedInitialCut {
                return ApprovalStep(number: number, label: label, state: .current,
                                    stateLabel: "Approved · awaiting revised upload", tone: .success)
            }
            if index == 2, let remaining = row.remainingExecutiveSignoffs, let left = execsLeft(remaining) {
                return ApprovalStep(number: number, label: label, state: .current, stateLabel: left, tone: .warning)
            }
            return ApprovalStep(number: number, label: label, state: .current, stateLabel: "Reviewing", tone: .warning)
        }
    }

    // MARK: Uploads

    static func uploadLabel(_ stage: StudentStage, hasMedia: Bool, allowSecondFinalCut: Bool) -> String {
        switch stage {
        case .aRoll: "Upload videos"
        case .initialCut: hasMedia ? "Upload new version" : "Upload Initial Cut"
        default: allowSecondFinalCut ? "Upload revised Final Cut" : "Upload Final Cut"
        }
    }

    static func uploadRule(_ stage: StudentStage, hasMedia: Bool) -> String? {
        switch stage {
        case .aRoll: "Pick A-roll or B-roll, then one or more clips. Up to 30 GB per A-roll file, 15 GB per B-roll file."
        case .initialCut where hasMedia: "Each upload is a new version of the same Initial Cut."
        default: nil
        }
    }

    static func finalCutRule(allowSecondFinalCut: Bool) -> String {
        allowSecondFinalCut
            ? "Second revision: you can replace this Final Cut. The quality score is capped at 75%. Late turn-in is a separate 20%/30% penalty."
            : "You can only upload Final Cut once unless the first grade is below 75%."
    }

    static func emptyMediaTitle(_ stage: StudentStage) -> String {
        stage == .finalCut ? "No Final Cut uploaded yet." : "No videos uploaded yet."
    }

    /// "Initial Cut Version 3" (the Portal's `initialCutVersionTitle`).
    static func cutTitle(version: Int) -> String { "Initial Cut Version \(version)" }

    // MARK: Versions

    /// One Initial Cut version's review result, as the student sees it.
    static func cutResult(_ media: StageMedia) -> (label: String, tone: StatusTag.Tone) {
        if media.approvalStatus == "NEEDS_CHANGES" { return ("Needs revisions", .danger) }
        if let stage = media.approvedInStage { return ("Approved in Stage \(stage)", .success) }
        if media.approvalStatus == "APPROVED" { return ("Approved", .success) }
        return ("Pending review", .warning)
    }

    /// READY → Ready; the raw enum never reaches the screen.
    static func mediaStatusLabel(_ status: String) -> String {
        switch status {
        case "READY": return "Ready"
        case "PROCESSING": return "Processing"
        case "UPLOADING": return "Uploading"
        case "FAILED": return "Failed"
        default:
            let lower = status.lowercased().replacingOccurrences(of: "_", with: " ")
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
    }

    /// The Portal page for a cut's timecoded review (`stageReviewHref`); Initial Cut opens it bare.
    static func reviewPath(_ media: StageMedia, bare: Bool) -> String? {
        guard let project = media.projectId else { return nil }
        return "projects/\(project)/review/\(media.id)" + (bare ? "?bare=1" : "")
    }

    /// A Portal link (`/projects/…?v=…`) as an in-app path without the leading slash.
    static func portalPath(_ href: String) -> String {
        href.hasPrefix("/") ? String(href.dropFirst()) : href
    }
}

/// Brainstorming's status and next step (`app/(app)/brainstorming/brainstorm-view.ts`).
enum BrainstormGuide {
    static let instructions =
        "Upload three proofs of contact and link the group Google Doc. Your producer reviews this on Groups and approves the check-in."

    static func isReady(_ package: BrainstormPackage) -> Bool {
        package.proofs.count >= BrainstormPackage.proofSlots.count && GoogleDocLink.isValid(package.brainstormDocUrl ?? "")
    }

    static func status(_ package: BrainstormPackage) -> StageStatus {
        if package.proofOfContact { return .approved }
        if !isReady(package) { return .pending }
        return package.needsChanges == true ? .needsRevisions : .submitted
    }

    static func nextStep(_ package: BrainstormPackage) -> String {
        switch status(package) {
        case .approved:
            return "Approved by your producer."
        case .needsRevisions:
            return "Your producer asked for changes. Read the feedback, then remove a proof and upload a new one to send it back for review."
        case .submitted:
            return "Everything is in. Waiting for \(package.assignedProducer?.displayName ?? "your producer") to review."
        default:
            let have = package.proofs.count
            let missing = max(0, BrainstormPackage.proofSlots.count - have)
            let needsDoc = !GoogleDocLink.isValid(package.brainstormDocUrl ?? "")
            let proofs = missing > 0 ? "\(missing) \(have > 0 ? "more " : "")\(missing == 1 ? "proof" : "proofs")" : ""
            if !proofs.isEmpty && needsDoc { return "Add \(proofs) and the Google Doc link." }
            if !proofs.isEmpty { return "Add \(proofs)." }
            return "Add the Google Doc link."
        }
    }

    /// Members, then the producer, like the other stage headers.
    static func metaLine(members: [PackagePerson], producer: PackagePerson?) -> String {
        let names = members.map(\.displayName).joined(separator: ", ")
        return "\(names.isEmpty ? "No members" : names) · Producer: \(producer?.displayName ?? "not assigned yet")"
    }
}

/// Producer notes on a single A-roll clip are stored as `[[clip:<mediaId>]]\n<text>`
/// in the stage thread (`src/lib/package-clip-comments.ts`).
enum ClipComment {
    static func parse(_ body: String) -> (clipId: String?, text: String) {
        let prefix = "[[clip:"
        guard body.hasPrefix(prefix), let close = body.range(of: "]]") else { return (nil, body) }
        let id = String(body[body.index(body.startIndex, offsetBy: prefix.count)..<close.lowerBound])
        guard !id.isEmpty, !id.contains("]") else { return (nil, body) }
        var rest = body[close.upperBound...]
        if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        return (id, String(rest))
    }
}
