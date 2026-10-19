import Foundation

/// Rules the Groups review pages share with the website, kept pure so they can be tested.
enum GroupReviewLogic {
    static let partMax = 25.0
    static let noteMax = 2000
    static let cycleFeedbackMax = 2000
    static let rosterNotesMax = 4000
    static let tossMax = 500
    /// `LATE_PENALTY_OVERRIDE_PERCENTS`.
    static let penaltyPercents = [5, 10, 15, 20, 30]
    static let approveAnywayConfirm = "Send this package to Stage 2 without a new upload? The adviser will review the latest version."

    // MARK: Who may act

    /// `producerMayActOnPackage`: executives, the adviser and the super admin act on any package;
    /// an associate only on the one assigned to them, and never on a package they're a member of.
    static func mayAct(_ user: PortalUser?, assignedProducerEmail: String?, memberEmails: [String]) -> Bool {
        guard let user, user.isProducer else { return false }
        if user.has(.executiveProducer) { return true }
        let me = user.email.lowercased()
        if memberEmails.contains(where: { $0.lowercased() == me }) { return false }
        return assignedProducerEmail?.lowercased() == me
    }

    static func mayAct(_ user: PortalUser?, on row: GroupRow) -> Bool {
        mayAct(user, assignedProducerEmail: row.assignedProducer?.email, memberEmails: row.members.compactMap(\.email))
    }

    // MARK: Initial Cut stages

    /// `approvalStageToReviewStage`.
    static func reviewStage(for approvalStage: String?) -> Int? {
        switch approvalStage {
        case "ASSOCIATE_REVIEW": 1
        case "ADVISER_REVIEW": 2
        case "EXECUTIVE_REVIEW", "APPROVED": 3
        default: nil
        }
    }

    struct ApprovalStep: Hashable, Identifiable {
        enum State: Hashable { case upcoming, current, done }
        let number: Int
        let label: String
        let state: State
        let stateLabel: String?
        let tone: StatusTag.Tone
        var id: Int { number }
    }

    /// The three-step approval path (`approvalPathSteps`).
    static func approvalPath(approvalStage: String, hasMedia: Bool, needsRevisions: Bool,
                             awaitingRevisedInitialCut: Bool, remainingExecutiveSignoffs: Int?) -> [ApprovalStep] {
        let labels = ["Producer review", "Adviser review", "Executive sign-off"]
        let order = ["DRAFT": 0, "ASSOCIATE_REVIEW": 0, "ADVISER_REVIEW": 1, "EXECUTIVE_REVIEW": 2, "APPROVED": 3]
        let current = hasMedia ? (order[approvalStage] ?? -1) : -1
        return labels.enumerated().map { index, label in
            let number = index + 1
            if current < 0 || index > current {
                return ApprovalStep(number: number, label: label, state: .upcoming, stateLabel: nil, tone: .neutral)
            }
            if index < current {
                return ApprovalStep(number: number, label: label, state: .done, stateLabel: "Done", tone: .success)
            }
            if needsRevisions || approvalStage == "DRAFT" {
                return ApprovalStep(number: number, label: label, state: .current, stateLabel: "Needs revisions", tone: .danger)
            }
            if index == 0 && awaitingRevisedInitialCut {
                return ApprovalStep(number: number, label: label, state: .current, stateLabel: "Approved · awaiting revised upload",
                                    tone: .success)
            }
            if index == 2, let left = remainingExecutiveSignoffs, left > 0 {
                return ApprovalStep(number: number, label: label, state: .current,
                                    stateLabel: left == 1 ? "1 exec left" : "\(left) execs left", tone: .warning)
            }
            return ApprovalStep(number: number, label: label, state: .current, stateLabel: "Reviewing", tone: .warning)
        }
    }

    // MARK: Final Cut scores

    /// Typed but unsaved scores for one member.
    struct ScoreDraft: Hashable {
        var quality = ""
        var effort = ""
    }

    static func draft(from members: [FinalCutMemberGrade]) -> [String: ScoreDraft] {
        Dictionary(uniqueKeysWithValues: members.map { member in
            (member.userId, ScoreDraft(quality: member.myQuality.map(points) ?? "", effort: member.myEffort.map(points) ?? ""))
        })
    }

    static func isDirty(_ members: [FinalCutMemberGrade], _ draft: [String: ScoreDraft]) -> Bool {
        let saved = self.draft(from: members)
        return members.contains { member in
            guard !member.locked else { return false }
            let typed = draft[member.userId] ?? ScoreDraft()
            let was = saved[member.userId] ?? ScoreDraft()
            return typed.quality.trimmingCharacters(in: .whitespaces) != was.quality
                || typed.effort.trimmingCharacters(in: .whitespaces) != was.effort
        }
    }

    enum Part: Equatable { case empty, invalid, value(Double) }

    static func parsePart(_ text: String) -> Part {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        guard let value = Double(trimmed), value.isFinite, value >= 0, value <= partMax else { return .invalid }
        return .value(value)
    }

    /// Filled rows become scores; a half-filled or out-of-range row is an error (`scoresFromDraft`).
    static func scores(_ members: [FinalCutMemberGrade], _ draft: [String: ScoreDraft]) -> Result<[FinalCutScoreInput], ScoreError> {
        var scores: [FinalCutScoreInput] = []
        for member in members where !member.locked {
            let entry = draft[member.userId] ?? ScoreDraft()
            let quality = parsePart(entry.quality)
            let effort = parsePart(entry.effort)
            if quality == .empty && effort == .empty { continue }
            guard case .value(let q) = quality, case .value(let e) = effort else {
                if quality == .empty || effort == .empty {
                    return .failure(ScoreError(message: "Enter both quality and effort for \(member.label)."))
                }
                return .failure(ScoreError(message: "Scores for \(member.label) must be between 0 and 25."))
            }
            scores.append(FinalCutScoreInput(memberUserId: member.userId, qualityPoints: q, effortPoints: e))
        }
        return scores.isEmpty ? .failure(ScoreError(message: "Enter at least one member's scores.")) : .success(scores)
    }

    struct ScoreError: Error, Equatable { let message: String }

    /// What Save tells the grader (`useFinalCutSaves`).
    static func savedMessage(_ result: FinalCutScoreResult) -> String {
        if result.savedCount == 0 { return "Nothing saved. Those members keep their earlier grade." }
        if result.complete { return "Saved. Every member has an official grade." }
        if result.gradedCount > 0 {
            return "Saved. \(result.gradedCount) member\(result.gradedCount == 1 ? "" : "s") now have an official grade."
        }
        return "Saved. Waiting on other executive producers."
    }

    /// Average, "Scored 75% or more…", or who the grade is still waiting on (`memberGradeSummary`).
    static func summary(_ member: FinalCutMemberGrade) -> String {
        let waitingOn = member.graderScores.filter { $0.required && !$0.scored }.map { firstName($0.name) }
        let base: String
        if member.complete {
            base = "Average quality \(pts(member.qualityAverage)) + effort \(pts(member.effortAverage)) = \(pts(member.average))"
        } else if member.locked {
            base = "Scored 75% or more before this revision."
        } else if !waitingOn.isEmpty {
            base = "Waiting on \(waitingOn.joined(separator: ", "))"
        } else {
            base = "Waiting on \(member.pendingCount) executive producer\(member.pendingCount == 1 ? "" : "s")"
        }
        return member.revisionCapped ? "\(base) · second revision cap \(pts(member.afterRevisionCap))" : base
    }

    // MARK: Late penalties

    struct LateStatus: Equatable {
        let label: String
        let tone: StatusTag.Tone
        let detail: String
    }

    /// The package's turn-in timing (`lateStatus`).
    static func lateStatus(_ grade: FinalCutGrade) -> LateStatus {
        guard let turnedIn = grade.turnedInAt else {
            return LateStatus(label: "Not submitted", tone: .neutral, detail: "No Final Cut file is on this package yet.")
        }
        if grade.daysLate <= 0 {
            return LateStatus(label: "On time", tone: .success, detail: "Submitted \(day(turnedIn)). No late deduction.")
        }
        let percent = percentOf(grade.penaltyMultiplier)
        let days = daysText(grade.daysLate)
        let deadline = day(grade.deadlineAt)
        if grade.blocksSecondRevision {
            return LateStatus(label: "Late · \(percent)% off", tone: .danger,
                              detail: "\(days) past the \(deadline) deadline. The automatic deduction is 30%, and a second revision cannot repair it. Each member's penalty is below.")
        }
        return LateStatus(label: "Late · \(percent)% off", tone: .warning,
                          detail: "\(days) past the \(deadline) deadline. The automatic deduction is \(percent)%. Each member's penalty is below.")
    }

    /// The Deduction cell's quiet line.
    static func deductionDetail(_ grade: FinalCutGrade) -> String {
        if grade.blocksSecondRevision { return "30% cannot be repaired" }
        if grade.penaltyMultiplier > 0 { return "Taken off the official grade" }
        return grade.secondRevisionEligible ? "Second revision still allowed" : "No late deduction"
    }

    /// "Auto −20%", "Auto · none" or "−15%" (`penaltyTriggerLabel`).
    static func penaltyLabel(_ member: FinalCutMemberGrade) -> String {
        if let percent = member.latePenaltyPercent { return "−\(percent)%" }
        let automatic = percentOf(member.automaticPenaltyMultiplier)
        return automatic > 0 ? "Auto −\(automatic)%" : "Auto · none"
    }

    /// The Automatic option's words (`automaticPenaltyLabel`).
    static func automaticPenaltyLabel(_ member: FinalCutMemberGrade) -> String {
        let automatic = percentOf(member.automaticPenaltyMultiplier)
        return automatic > 0 ? "−\(automatic)% · \(daysText(member.daysLate)) late" : "none, on time"
    }

    /// What a non-executive sees for a member's penalty.
    static func effectivePenalty(_ member: FinalCutMemberGrade) -> String {
        let effective = percentOf(member.penaltyMultiplier)
        let base = effective > 0 ? "−\(effective)%" : "None"
        return member.latePenaltyPercent != nil ? "\(base) · set by an executive producer" : base
    }

    // MARK: Toss

    /// `tossError`: why a toss can't be used, or nil.
    static func tossError(_ toss: String) -> String? {
        let trimmed = toss.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Add a toss for the anchors." }
        if trimmed.count > tossMax { return "Keep the toss to \(tossMax) characters or fewer." }
        if trimmed.contains(where: { "<>[]{}".contains($0) }) { return "The toss can't include < > [ ] { }." }
        return nil
    }

    // MARK: Formatting

    static func percentOf(_ multiplier: Double) -> Int { Int((multiplier * 100).rounded()) }

    static func pts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    /// A score as typed back into a field: "20", "12.5".
    static func points(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }

    static func daysText(_ days: Double) -> String {
        let text = days.rounded() == days ? String(Int(days)) : String(format: "%.1f", days)
        return "\(text) day\(days == 1 ? "" : "s")"
    }

    static func day(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func firstName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? name
    }
}
