import SwiftUI

/// Initial Cut on Groups (the website's Initial 1/2/3 tabs): the approval path, which review
/// stage you're looking at, its versions, and the decisions the Portal allows this producer:
/// Needs revisions, Approve (or Approve anyway after a send-back), Unapprove, and Approve anyway
/// to Stage 2. Stage 1 is the assigned producer, Stage 2 the adviser, Stage 3 two executives.
struct InitialCutReviewSection: View {
    let rowId: String
    let group: GroupRow
    let view: StageView
    @Binding var reviewStage: Int
    let service: GroupReviewService
    let reload: () async -> Void
    let play: (StageMedia) -> Void
    /// After a decision that adds a note to the feedback thread.
    var onNoteAdded: () -> Void = {}

    @Environment(Router.self) private var router
    @State private var approving = false
    @State private var sendingBack = false
    @State private var confirmAnyway = false
    @State private var confirmUnapprove = false
    @State private var busy = false
    @State private var error: String?

    private var media: [StageMedia] { view.media ?? [] }
    private var approval: CutApproval? { view.cutApproval }
    private var row: StageRow? { view.row }
    private var currentStage: Int? { GroupReviewLogic.reviewStage(for: row?.approvalStage ?? group.approvalStage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            approvalPath
            stagePicker
            otherStageNote
            versions
            actions
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
            }
        }
        .sheet(isPresented: $approving) {
            DecisionSheet(stageTitle: "Initial Cut · Stage \(reviewStage)") { note in
                try await decide(.approve(note: note, versionId: media.first?.versionId))
            }
        }
        .sheet(isPresented: $sendingBack) {
            RevisionsSheet(canAddNote: view.canComment) { note in
                if !note.isEmpty {
                    try await service.postNote(rowId: rowId, stage: GroupStage.initialCut.rawValue, body: note)
                }
                try await decide(.needsRevisions(versionId: media.first?.versionId))
                onNoteAdded()
            }
        }
        .confirmationDialog("Approve anyway?", isPresented: $confirmAnyway, titleVisibility: .visible) {
            Button("Send to Stage 2") { Task { try? await decide(.approveAnyway) } }
        } message: {
            Text(GroupReviewLogic.approveAnywayConfirm)
        }
        .confirmationDialog("Withdraw your approval?", isPresented: $confirmUnapprove, titleVisibility: .visible) {
            Button("Unapprove") { Task { try? await decide(.unapprove) } }
        } message: {
            Text("The package goes back to this stage. Later approvals are cleared.")
        }
    }

    // MARK: Pieces

    private var approvalPath: some View {
        let steps = GroupReviewLogic.approvalPath(
            approvalStage: row?.approvalStage ?? group.approvalStage,
            hasMedia: group.initialCutMediaItemId != nil || !media.isEmpty,
            needsRevisions: row?.initialCutNeedsRevisions ?? group.initialCutNeedsRevisions,
            awaitingRevisedInitialCut: row?.awaitingRevisedInitialCut ?? group.awaitingRevisedInitialCut,
            remainingExecutiveSignoffs: row?.remainingExecutiveSignoffs ?? group.remainingExecutiveSignoffs)
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Approval path")
            ForEach(steps) { step in
                HStack(spacing: 10) {
                    Image(systemName: step.state == .done ? "checkmark.circle.fill" : step.state == .current ? "circle.inset.filled" : "circle")
                        .foregroundStyle(step.state == .upcoming ? Brand.muted : Brand.green)
                        .accessibilityHidden(true)
                    Text("\(step.number). \(step.label)").font(.bodyText).foregroundStyle(Brand.foreground)
                    Spacer()
                    if let label = step.stateLabel { StatusTag(text: label, tone: step.tone) }
                }
                .frame(minHeight: 32)
                .accessibilityElement(children: .combine)
            }
        }
        .card(padding: 12)
    }

    private var stagePicker: some View {
        HStack(spacing: 8) {
            ForEach(1...3, id: \.self) { stage in
                Chip(title: "Initial \(stage)", selected: reviewStage == stage) {
                    guard reviewStage != stage else { return }
                    reviewStage = stage
                }
                .accessibilityLabel("Initial Cut, stage \(stage)\(stage == currentStage ? ", current" : "")")
            }
        }
    }

    @ViewBuilder private var otherStageNote: some View {
        if let current = currentStage, current != reviewStage {
            HStack {
                Text(row?.approvalStage == "APPROVED" ? "Approved for Final Cut." : "This package is in Stage \(current).")
                    .font(.small).foregroundStyle(Brand.secondary)
                Spacer()
                if row?.approvalStage == "APPROVED" {
                    Button("Go to Final") { router.push(.work(.group(rowId: rowId, stage: GroupStage.finalCut.rawValue))) }
                        .font(.lexend(14, .medium)).foregroundStyle(Brand.green).frame(minHeight: 44)
                } else {
                    Button("Go to Initial \(current)") { reviewStage = current }
                        .font(.lexend(14, .medium)).foregroundStyle(Brand.green).frame(minHeight: 44)
                }
            }
            .card(padding: 12)
        }
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: media.isEmpty ? "Versions" : "Versions · \(media.count)")
            if media.isEmpty {
                Text(emptyTitle).font(.small).foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                ForEach(media) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        StageMediaCard(media: item) { play(item) }
                        HStack {
                            if let stage = item.approvedInStage { StatusTag(text: "Approved in Stage \(stage)", tone: .success) }
                            if item.approvalStatus == "NEEDS_CHANGES" { StatusTag(text: "Needs revisions", tone: .danger) }
                            Spacer()
                            if let route = item.reviewRoute {
                                Button("Open review · v\(item.versionNumber)") { router.push(.review(route)) }
                                    .font(.lexend(14, .medium))
                                    .foregroundStyle(Brand.green)
                                    .frame(minHeight: 44)
                                    .hiddenInSampleApp()
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        switch reviewStage {
        case 2: "No Stage 2 cut yet. Approve Stage 1 first."
        case 3: "No Stage 3 cut yet. Approve Stage 2 first."
        default: "No videos uploaded yet."
        }
    }

    @ViewBuilder private var actions: some View {
        let onCurrentTab = reviewStage == GroupReviewLogic.reviewStage(for: approval?.stage)
        let canDecide = approval?.canAct == true && onCurrentTab && !media.isEmpty
        VStack(spacing: 10) {
            if canDecide {
                Button((row?.initialCutNeedsRevisions ?? false) ? "Approve anyway" : "Approve") { approving = true }
                    .buttonStyle(.brandPrimary)
                Button("Needs revisions") { sendingBack = true }
                    .buttonStyle(.brandSecondary)
                    .accessibilityLabel("Submit review, needs revisions")
            }
            if approval?.canApproveAnyway == true {
                Button("Approve anyway") { confirmAnyway = true }
                    .buttonStyle(.brandSecondary)
                    .accessibilityHint("Sends the latest version to Stage 2 without a new upload")
            }
            if approval?.canUnapprove == true {
                Button("Unapprove") { confirmUnapprove = true }
                    .buttonStyle(.brandSecondary)
            }
        }
        .disabled(busy)
    }

    private func decide(_ action: CutAction) async throws {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await service.decideCut(rowId: rowId, action)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await reload()
        } catch {
            self.error = Loadable<Void>.message(for: error)
            throw error
        }
    }
}
