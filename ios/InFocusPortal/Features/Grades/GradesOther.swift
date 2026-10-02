import SwiftUI

/// Livestream hours and the portfolio (web Other view).
struct GradesOther: View {
    let grades: GradesMe

    var body: some View {
        let livestream = grades.estimated?.packages.livestreamPoints
        let hours = grades.gradebook?.livestreamHours ?? 0
        let required = grades.gradebook?.requiredLivestreamHours ?? 8
        let portfolio = grades.estimated?.portfolio.points
        let feedback = grades.gradebook?.portfolioFeedback.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Livestreams", color: Brand.muted)
                GradePointsCell(label: "Points", value: livestream, max: GradesPresentation.maxLivestreamPoints)
                HStack {
                    Text("Hours completed").font(.bodyText).foregroundStyle(Brand.secondary)
                    Spacer()
                    Text("\(GradesPresentation.points(hours)) / \(GradesPresentation.points(required))")
                        .font(.mono(15, .medium))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                GradeProgressBar(fraction: required > 0 ? hours / required : 0)
                Text(livestream == nil
                     ? "Full credit is \(GradesPresentation.points(required)) hours a semester. The grade shows once livestream grades are released."
                     : "Full credit is \(GradesPresentation.points(required)) hours a semester (5 points an hour).")
                    .font(.small)
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Portfolio", color: Brand.muted)
                GradePointsCell(label: "Points", value: portfolio, max: GradesPresentation.maxPortfolioPoints)
                Text(portfolio == nil
                     ? "Not graded yet. The 10% portfolio weight is dropped until it is marked."
                     : "Counts as 10% of the semester grade.")
                    .font(.small)
                    .foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !feedback.isEmpty {
                    Eyebrow("Feedback", color: Brand.muted, size: 11)
                    Text(feedback)
                        .font(.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .card()
        }
    }
}
