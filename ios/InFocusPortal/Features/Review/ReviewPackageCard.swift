import SwiftUI

/// An Initial Cut's package review on the review screen: the approval path, and for a producer
/// with a decision to make, a way to the Groups stage where the decisions live.
struct ReviewPackageCard: View {
    let review: ReviewDetail.PackageReview
    let latest: ReviewVersion?
    let openDecisions: () -> Void

    private var steps: [GroupReviewLogic.ApprovalStep] {
        GroupReviewLogic.approvalPath(approvalStage: review.stage, hasMedia: true,
                                      needsRevisions: latest?.approvalStatus == .needsChanges,
                                      awaitingRevisedInitialCut: review.awaitingRevisedInitialCut ?? false,
                                      remainingExecutiveSignoffs: review.remainingExecutiveSignoffs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Package review")
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
            if review.hasDecision {
                if review.canApprove && review.awaitingRevisedInitialCut != true {
                    Text("Leave comments, then submit review to request revisions, or approve this stage.")
                        .font(.small)
                        .foregroundStyle(Brand.secondary)
                }
                Button("Review decisions", action: openDecisions)
                    .buttonStyle(.brandSecondary)
                    .hiddenInSampleApp()
            }
        }
        .card(padding: 12)
    }
}
