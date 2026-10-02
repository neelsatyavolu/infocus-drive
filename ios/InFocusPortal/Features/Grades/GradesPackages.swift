import SwiftUI

/// This semester's package cycles: final cut and check-in points, which
/// check-in stages are done, and published feedback (web Packages view).
struct GradesPackages: View {
    let grades: GradesMe

    var body: some View {
        let cycles = GradesPresentation.semesterCycles(grades)
        VStack(alignment: .leading, spacing: 16) {
            if cycles.isEmpty {
                EmptyStateView(title: "No cycles yet", message: "Package cycles show up here once they start.")
            } else {
                ForEach(cycles) { cycle in
                    CycleGradeCard(cycle: cycle, grades: grades)
                }
            }
        }
    }
}

private struct CycleGradeCard: View {
    let cycle: GradesMe.CycleGrade
    let grades: GradesMe
    @Environment(Router.self) private var router

    private static let stages: [(label: String, done: (GradesMe.CheckIn) -> Bool)] = [
        ("Pitch", \.pitching), ("Brainstorm", \.proofOfContact), ("A/B", \.aRollBRoll), ("Initial", \.initialCut)
    ]

    var body: some View {
        let scores = GradesPresentation.scores(for: cycle, in: grades)
        let checkIn = grades.gradebook?.checkIns.first { $0.cycleNumber == cycle.cycleNumber }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(GradesPresentation.cycleTitle(cycle))
                    .headline(.h3)
                Spacer(minLength: 8)
                StatusTag(text: GradesPresentation.cycleStatus(cycle), tone: cycle.published ? .success : .warning)
            }
            HStack(spacing: 8) {
                GradePointsCell(label: "Final cut", value: scores.finalCut, max: GradesPresentation.maxFinalCutPoints)
                GradePointsCell(label: "Check-ins", value: scores.checkIn, max: scores.checkInMax)
            }
            HStack(spacing: 6) {
                ForEach(Self.stages, id: \.label) { stage in
                    let done = checkIn.map(stage.done) ?? false
                    Text(done ? "\(stage.label) ✓" : stage.label)
                        .font(.lexend(12, .medium, relativeTo: .caption))
                        .foregroundStyle(done ? Brand.foreground : Brand.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(done ? Brand.greenTint : Brand.raised, in: RoundedRectangle(cornerRadius: Brand.tagRadius))
                        .accessibilityLabel("\(stage.label) check-in \(done ? "done" : "not done")")
                }
            }
            if cycle.published, let feedback = cycle.feedback?.trimmingCharacters(in: .whitespacesAndNewlines), !feedback.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Producer feedback", color: Brand.muted, size: 11)
                    Text(feedback)
                        .font(.bodyText)
                        .foregroundStyle(Brand.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if cycle.published, let project = cycle.reviewProjectId, let media = cycle.reviewMediaId {
                Button("Open the graded cut") {
                    router.openPortal("projects/\(project)/review/\(media)", title: "Final cut")
                }
                .buttonStyle(.brandSecondary)
            }
        }
        .card()
    }
}
