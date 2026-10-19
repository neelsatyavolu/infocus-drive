import SwiftUI

/// Member grades on a Final Cut (the website's `FinalCutGradeCard`): each executive producer's
/// progress, deadline / submitted / deduction, each member's scores, every grader's numbers,
/// the official grade, and the late penalty, which executives can replace per member.
struct FinalCutGradeSection: View {
    let rowId: String
    let grade: FinalCutGrade
    /// Save my scores is the page's one filled button (not when Publish grades is next).
    var savePrimary = true
    let service: GroupReviewService
    let reload: () async -> Void

    @State private var draft: [String: GroupReviewLogic.ScoreDraft] = [:]
    @State private var savedKey = ""
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?
    @State private var penaltyBusy: String?
    @State private var showHow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let timing = GroupReviewLogic.lateStatus(grade)
            HStack {
                SectionHeader(title: "Member grades")
                StatusTag(text: timing.label, tone: timing.tone)
            }
            graders
            timingStrip
            if grade.daysLate > 0 {
                Text(timing.detail)
                    .font(.small)
                    .foregroundStyle(grade.blocksSecondRevision ? Brand.danger : Brand.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("How grading works", isExpanded: $showHow) {
                Text("Each executive producer scores every member: quality out of 25 and effort out of 25. A member's official grade is the average of those totals, then any revision cap and late deduction.")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
                    .padding(.top, 6)
            }
            .font(.lexend(14, .medium))
            .tint(Brand.muted)

            if grade.members.isEmpty {
                Text("This package has no members.").font(.small).foregroundStyle(Brand.muted)
            } else {
                ForEach(grade.members) { member in memberCard(member) }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
            }
            if let message {
                Text(message).font(.small).foregroundStyle(Brand.secondary)
            }
            if canSave {
                let button = Button(saving ? "Saving…" : "Save my scores") { Task { await save() } }.disabled(saving || !dirty)
                if savePrimary { button.buttonStyle(.brandPrimary) } else { button.buttonStyle(.brandSecondary) }
            } else if !grade.canGrade {
                Text("Only executive producers enter scores.").font(.small).foregroundStyle(Brand.muted)
            }
        }
        .onAppear { resetIfSaved() }
        .onChange(of: key) { resetIfSaved() }
    }

    // MARK: Pieces

    private var graders: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Graders", color: Brand.muted)
            if grade.graders.isEmpty {
                Text("No executive producers are assigned yet.").font(.small).foregroundStyle(Brand.muted)
            } else {
                GroupTagFlow(items: grade.graders.map { grader in
                    let done = grade.scoringMembers > 0 && grader.scoredCount >= grade.scoringMembers
                    let you = grader.userId == grade.viewerUserId ? " (you)" : ""
                    let optional = grader.required ? "" : " · optional"
                    let progress = done ? "Done" : "\(min(grader.scoredCount, grade.scoringMembers))/\(grade.scoringMembers)"
                    return (grader.id, "\(grader.label)\(you)\(optional) · \(progress)", done ? StatusTag.Tone.success : .neutral)
                })
            }
        }
    }

    private var timingStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            cell("Deadline", GroupReviewLogic.day(grade.deadlineAt),
                 grade.extensionDays > 0 ? "Includes +\(GroupReviewLogic.points(grade.extensionDays)) extension days" : "No extension")
            Divider().overlay(Brand.line)
            cell("Submitted", GroupReviewLogic.day(grade.turnedInAt),
                 grade.daysLate > 0 ? "\(GroupReviewLogic.daysText(grade.daysLate)) late" : "On or before deadline")
            Divider().overlay(Brand.line)
            cell("Deduction",
                 grade.penaltyMultiplier > 0 ? "−\(GroupReviewLogic.percentOf(grade.penaltyMultiplier))% late" : "None",
                 GroupReviewLogic.deductionDetail(grade))
        }
        .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
    }

    private func cell(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(label, color: Brand.muted)
            Text(value).font(.lexend(15, .medium)).foregroundStyle(Brand.foreground)
            Text(detail).font(.small).foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private func memberCard(_ member: FinalCutMemberGrade) -> some View {
        let editable = grade.canGrade && !member.locked
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(member.label).font(.h3).foregroundStyle(Brand.foreground)
                if member.locked { StatusTag(text: "Locked", tone: .neutral) }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Eyebrow("Official", color: Brand.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(GroupReviewLogic.pts(member.officialPoints)).font(.mono(20, .medium)).foregroundStyle(Brand.foreground)
                        Text("/ 50").font(.mono(12)).foregroundStyle(Brand.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if editable {
                HStack(spacing: 10) {
                    scoreField("Quality", member: member, keyPath: \.quality)
                    scoreField("Effort", member: member, keyPath: \.effort)
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow("Yours", color: Brand.muted)
                        Text(typedTotal(member))
                            .font(.mono(17, .medium))
                            .foregroundStyle(Brand.foreground)
                            .frame(minHeight: 44)
                    }
                    .frame(width: 64, alignment: .leading)
                }
            }
            Text(GroupReviewLogic.summary(member)).font(.small).foregroundStyle(Brand.secondary)
            let scored = member.graderScores.filter(\.scored)
            if !scored.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(scored) { score in
                        HStack(spacing: 6) {
                            Text(GroupReviewLogic.firstName(score.name) + (score.userId == grade.viewerUserId ? " (you)" : ""))
                                .foregroundStyle(Brand.muted)
                            Text("\(GroupReviewLogic.pts(score.quality)) + \(GroupReviewLogic.pts(score.effort)) = \(GroupReviewLogic.pts((score.quality ?? 0) + (score.effort ?? 0)))")
                                .font(.mono(12))
                                .foregroundStyle(Brand.foreground)
                        }
                        .font(.small)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            penaltyRow(member)
        }
        .card(padding: 14)
    }

    private func scoreField(_ label: String, member: FinalCutMemberGrade,
                            keyPath: WritableKeyPath<GroupReviewLogic.ScoreDraft, String>) -> some View {
        let binding = Binding<String>(
            get: { (draft[member.userId] ?? .init())[keyPath: keyPath] },
            set: { value in
                var entry = draft[member.userId] ?? .init()
                entry[keyPath: keyPath] = value
                draft[member.userId] = entry
                message = nil
            }
        )
        let invalid = GroupReviewLogic.parsePart(binding.wrappedValue) == .invalid
        return VStack(alignment: .leading, spacing: 4) {
            Eyebrow("\(label) /25", color: Brand.muted)
            TextField("0–25", text: binding)
                .keyboardType(.decimalPad)
                .font(.mono(17, .medium))
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(invalid ? Brand.danger : Brand.control))
                .accessibilityLabel("\(label) for \(member.label), out of 25")
        }
    }

    @ViewBuilder
    private func penaltyRow(_ member: FinalCutMemberGrade) -> some View {
        HStack {
            Text("Late penalty").font(.small).foregroundStyle(Brand.muted)
            Spacer()
            if grade.canGrade {
                Menu {
                    penaltyOption("Automatic (\(GroupReviewLogic.automaticPenaltyLabel(member)))",
                                  selected: member.latePenaltyPercent == nil) { Task { await setPenalty(member, nil) } }
                    ForEach(GroupReviewLogic.penaltyPercents, id: \.self) { percent in
                        penaltyOption("−\(percent)%", selected: member.latePenaltyPercent == percent) {
                            Task { await setPenalty(member, percent) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if penaltyBusy == member.userId { ProgressView().controlSize(.small) }
                        Text(GroupReviewLogic.penaltyLabel(member)).font(.mono(13, .medium))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                    }
                    .foregroundStyle(Brand.foreground)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                }
                .disabled(penaltyBusy != nil)
                .accessibilityLabel("Late penalty for \(member.label): \(GroupReviewLogic.penaltyLabel(member))")
            } else {
                Text(GroupReviewLogic.effectivePenalty(member)).font(.small).foregroundStyle(Brand.foreground)
            }
        }
    }

    private func penaltyOption(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    // MARK: State

    private var key: String {
        grade.members.map { "\($0.userId):\($0.myQuality ?? -1):\($0.myEffort ?? -1)" }.joined(separator: "|")
    }

    private var canSave: Bool { grade.canGrade && grade.scoringMembers > 0 }
    private var dirty: Bool { GroupReviewLogic.isDirty(grade.members, draft) }

    private func typedTotal(_ member: FinalCutMemberGrade) -> String {
        let entry = draft[member.userId] ?? .init()
        guard case .value(let q) = GroupReviewLogic.parsePart(entry.quality),
              case .value(let e) = GroupReviewLogic.parsePart(entry.effort) else { return "—" }
        return GroupReviewLogic.pts(q + e)
    }

    /// Typed scores reset only when saved scores change, so a quiet reload keeps unsaved input.
    private func resetIfSaved() {
        guard key != savedKey else { return }
        savedKey = key
        draft = GroupReviewLogic.draft(from: grade.members)
    }

    private func save() async {
        switch GroupReviewLogic.scores(grade.members, draft) {
        case .failure(let problem):
            error = problem.message
        case .success(let scores):
            error = nil
            saving = true
            defer { saving = false }
            do {
                let result = try await service.saveScores(rowId: rowId, scores: scores)
                message = GroupReviewLogic.savedMessage(result)
                UINotificationFeedbackGenerator().notificationOccurred(result.savedCount > 0 ? .success : .warning)
                await reload()
            } catch {
                self.error = Loadable<Void>.message(for: error)
            }
        }
    }

    private func setPenalty(_ member: FinalCutMemberGrade, _ percent: Int?) async {
        penaltyBusy = member.userId
        defer { penaltyBusy = nil }
        do {
            try await service.setLatePenalty(rowId: rowId, memberUserId: member.userId, percent: percent)
            message = percent.map { "Late penalty set to \($0)%." } ?? "Late penalty set back to automatic."
            await reload()
        } catch {
            self.error = Loadable<Void>.message(for: error)
        }
    }
}

/// Tags that wrap onto as many lines as they need.
struct GroupTagFlow: View {
    let items: [(id: String, text: String, tone: StatusTag.Tone)]

    var body: some View {
        GroupWrapLayout(spacing: 6) {
            ForEach(items, id: \.id) { item in StatusTag(text: item.text, tone: item.tone) }
        }
    }
}

/// A simple wrapping row layout.
struct GroupWrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
