import SwiftUI

/// The producer Final Cut tab (the website's `FinalCutProducerView`): the cut, what airs
/// (headline and the anchors' toss), Send to queue, the shared cycle grade note with Publish
/// grades, Package of the Cycle voting, then member grades. Grading is for executive producers
/// (`isExecutiveProducer`; the adviser never grades) and the Portal enforces it.
struct FinalCutReviewSection: View {
    let rowId: String
    let view: StageView
    let extras: GroupStageExtras
    let service: GroupReviewService
    let reload: () async -> Void
    let play: (StageMedia) -> Void

    @State private var editingToss = false
    @State private var queueing = false
    @State private var feedbackDraft = ""
    @State private var feedbackSeen: String?
    @State private var savingFeedback = false
    @State private var publishing = false
    @State private var confirmPublish = false
    @State private var voting = false
    @State private var error: String?

    private var media: [StageMedia] { view.media ?? [] }
    private var row: StageRow? { view.row }
    private var grade: FinalCutGrade? { extras.finalCutGrade }

    /// `finalCutPrimaryAction`: graders publish when ready or save scores; others queue.
    private var primary: String? {
        let ready = grade.map { $0.complete && !$0.published } ?? false
        if grade?.canGrade == true {
            if ready { return "publish" }
            return (grade?.scoringMembers ?? 0) > 0 ? "save" : nil
        }
        if !media.isEmpty && row?.queuedForAirAt == nil { return "queue" }
        return ready ? "publish" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Final Cut")
                if media.isEmpty {
                    Text("No Final Cut uploaded yet.").font(.small).foregroundStyle(Brand.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).card()
                } else {
                    ForEach(media) { item in StageMediaCard(media: item) { play(item) } }
                }
                if !media.isEmpty { queueButton }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
            }
            if !media.isEmpty { whatAirs }
            if let grade { cycleGrade(grade) }
            if !media.isEmpty, let panel = extras.packageOfCycle { packageOfCycle(panel) }
            if let grade {
                FinalCutGradeSection(rowId: rowId, grade: grade, savePrimary: primary == "save", service: service, reload: reload)
            } else {
                EmptyStateView(title: "Scoring isn't open yet", message: "Final Cut scoring is not available yet.").card()
            }
        }
        .sheet(isPresented: $editingToss) {
            GroupTextSheet(title: "Toss", message: "The anchors read this right before the package airs. A few sentences.",
                           placeholder: "Last month, the robotics team… InFocus reporters Abby and Otto went there to learn more.",
                           actionTitle: "Save toss", maxLength: GroupReviewLogic.tossMax, allowsEmpty: false,
                           validate: { GroupReviewLogic.tossError($0) }, initial: row?.toss ?? "") { toss in
                try await service.saveToss(rowId: rowId, toss: toss)
                await reload()
            }
        }
        .confirmationDialog("Publish grades?", isPresented: $confirmPublish, titleVisibility: .visible) {
            Button("Publish grades") { Task { await publish() } }
        } message: {
            Text("Students see this cycle grade and the note on Grades. This can't be undone here.")
        }
    }

    // MARK: Queue

    private var queueButton: some View {
        let queued = row?.queuedForAirAt != nil
        let button = Button {
            Task { await setQueued(!queued) }
        } label: {
            Label(queueing ? "Saving…" : queued ? "Remove from queue" : "Send to queue",
                  systemImage: queued ? "tray.and.arrow.up" : "paperplane")
        }
        .disabled(queueing)
        return Group {
            if !queued && primary == "queue" { button.buttonStyle(.brandPrimary) } else { button.buttonStyle(.brandSecondary) }
        }
    }

    private func setQueued(_ queued: Bool) async {
        queueing = true
        error = nil
        defer { queueing = false }
        do {
            try await service.setQueued(rowId: rowId, queued: queued)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await reload()
        } catch {
            self.error = Loadable<Void>.message(for: error)
        }
    }

    // MARK: What airs

    private var whatAirs: some View {
        let toss = (row?.toss ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "What airs")
                if toss.isEmpty { StatusTag(text: "No toss", tone: .warning) }
            }
            VStack(alignment: .leading, spacing: 10) {
                if let headline = row?.headline, !headline.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Eyebrow("Headline", color: Brand.muted)
                        Text(headline).font(.lexend(16, .medium)).foregroundStyle(Brand.foreground)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow("Toss", color: Brand.muted)
                    Text(toss.isEmpty ? "No toss yet. The anchors read it right before this package airs." : toss)
                        .font(.bodyText)
                        .foregroundStyle(toss.isEmpty ? Brand.muted : Brand.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if extras.canEditToss == true {
                    Button(toss.isEmpty ? "Add a toss" : "Edit toss") { editingToss = true }
                        .buttonStyle(.brandSecondary)
                }
            }
            .card()
        }
    }

    // MARK: Cycle grade

    private func cycleGrade(_ grade: FinalCutGrade) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Cycle grade")
                StatusTag(text: grade.published ? "Published" : "Hidden", tone: grade.published ? .success : .neutral)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Same note for every producer.").font(.small).foregroundStyle(Brand.muted)
                TextField("Feedback for this group's cycle grade…", text: $feedbackDraft, axis: .vertical)
                    .font(.bodyText)
                    .lineLimit(4...10)
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                    .accessibilityLabel("Cycle grade feedback")
                HStack {
                    Text(grade.published
                         ? grade.publishedAt.map { "Visible on Grades since \(GroupReviewLogic.day($0))." } ?? "Visible on the student Grades tab."
                         : "Students cannot see this cycle grade until you publish.")
                        .font(.small).foregroundStyle(Brand.muted)
                    Spacer()
                    Text("\(feedbackDraft.count)/\(GroupReviewLogic.cycleFeedbackMax)")
                        .font(.mono(12))
                        .foregroundStyle(feedbackDraft.count > GroupReviewLogic.cycleFeedbackMax ? Brand.danger : Brand.muted)
                }
                let busy = savingFeedback || publishing
                Button(savingFeedback ? "Saving…" : "Save feedback") { Task { await saveFeedback() } }
                    .buttonStyle(.brandSecondary)
                    .disabled(busy || feedbackDraft == grade.feedback || feedbackDraft.count > GroupReviewLogic.cycleFeedbackMax)
                if !grade.published {
                    let publishButton = Button(publishing ? "Publishing…" : "Publish grades") { confirmPublish = true }
                        .disabled(busy || feedbackDraft.count > GroupReviewLogic.cycleFeedbackMax)
                    if primary == "publish" { publishButton.buttonStyle(.brandPrimary) } else { publishButton.buttonStyle(.brandSecondary) }
                }
            }
            .card()
        }
        .onAppear { syncFeedback(grade.feedback) }
        .onChange(of: grade.feedback) { _, value in syncFeedback(value) }
    }

    private func syncFeedback(_ saved: String) {
        guard feedbackSeen != saved else { return }
        feedbackSeen = saved
        feedbackDraft = saved
    }

    private func saveFeedback() async {
        savingFeedback = true
        error = nil
        defer { savingFeedback = false }
        do {
            try await service.saveCycleFeedback(rowId: rowId, feedback: feedbackDraft)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await reload()
        } catch {
            self.error = Loadable<Void>.message(for: error)
        }
    }

    private func publish() async {
        publishing = true
        error = nil
        defer { publishing = false }
        do {
            try await service.publishGrades(rowId: rowId, feedback: feedbackDraft)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await reload()
        } catch {
            self.error = Loadable<Void>.message(for: error)
        }
    }

    // MARK: Package of the Cycle

    private func packageOfCycle(_ panel: PackageOfCyclePanel) -> some View {
        let awarded = panel.awardedAt != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Package of the Cycle")
                StatusTag(text: awarded ? "Awarded" : "\(panel.votes)/\(panel.graders.count) votes", tone: awarded ? .success : .neutral)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Every executive producer has to vote for it. Up to 2 packages win each cycle.")
                    .font(.small).foregroundStyle(Brand.muted)
                if !panel.graders.isEmpty {
                    GroupTagFlow(items: panel.graders.map { ($0.id, $0.voted ? "\($0.name) · voted" : $0.name, $0.voted ? .success : .neutral) })
                }
                if panel.canVote {
                    Button(voting ? "Saving…" : panel.myVote ? "Withdraw my vote" : "Vote for Package of the Cycle") {
                        Task { await vote(!panel.myVote) }
                    }
                    .buttonStyle(.brandSecondary)
                    .disabled(voting || panel.voteBlocked)
                    if panel.voteBlocked, let reason = panel.blockedReason {
                        Text(reason).font(.small).foregroundStyle(Brand.muted)
                    }
                }
                if awarded, let members = row?.members, !members.isEmpty {
                    Divider().overlay(Brand.line)
                    Eyebrow("Certificates", color: Brand.muted)
                    ForEach(members, id: \.self) { member in
                        Button {
                            Task { await certificate(member) }
                        } label: {
                            Label(member.displayName, systemImage: "arrow.down.circle")
                                .font(.bodyText)
                                .foregroundStyle(Brand.foreground)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .hiddenInSampleApp()
                    }
                }
            }
            .card()
        }
    }

    private func vote(_ next: Bool) async {
        voting = true
        error = nil
        defer { voting = false }
        do {
            _ = try await service.votePackageOfCycle(rowId: rowId, vote: next)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await reload()
        } catch {
            self.error = Loadable<Void>.message(for: error)
        }
    }

    private func certificate(_ member: PackagePerson) async {
        guard let memberId = member.userId else { return }
        do {
            let file = try await service.certificate(rowId: rowId, memberId: memberId, name: member.displayName)
            Presenter.share(file)
        } catch {
            self.error = Loadable<Void>.message(for: error)
        }
    }
}
