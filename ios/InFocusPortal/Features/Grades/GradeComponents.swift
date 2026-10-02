import SwiftUI

/// The estimated letter grade and percent, large.
struct GradeLetter: View {
    let letter: String?
    let percentage: Double?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(letter ?? "—")
                .font(.lexend(44, .semibold, relativeTo: .largeTitle))
                .foregroundStyle(letter == nil ? Brand.muted : Brand.foreground)
            Text(percentage.map { String(format: "%.1f%%", $0) } ?? "Not gradeable yet")
                .font(.mono(13, .medium))
                .monospacedDigit()
                .foregroundStyle(Brand.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(letter.map { "Estimated grade \($0), \(percentage.map { String(format: "%.1f percent", $0) } ?? "")" }
                            ?? "Estimated grade not gradeable yet")
    }
}

/// One category of the semester grade: earned / possible, its weight and a bar.
struct GradeCategoryCard: View {
    let title: String
    let weight: String
    let totals: GradesPresentation.Totals
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(title, color: Brand.muted)
                Spacer()
                Text(weight)
                    .font(.small)
                    .foregroundStyle(Brand.muted)
            }
            Text(totals.possible > 0 ? "\(GradesPresentation.points(totals.earned)) / \(GradesPresentation.points(totals.possible))" : "—")
                .font(.mono(24, .medium))
                .monospacedDigit()
                .foregroundStyle(Brand.foreground)
            Text(totals.percent.map { "\(GradesPresentation.points($0))% of category" } ?? "Not gradeable yet")
                .font(.small)
                .foregroundStyle(Brand.secondary)
            if let percent = totals.percent {
                GradeProgressBar(fraction: percent / 100)
            }
            Text(hint)
                .font(.lexend(12, relativeTo: .caption))
                .foregroundStyle(Brand.muted)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// A flat bar: green fill on a raised track.
struct GradeProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Brand.raised)
                Rectangle().fill(Brand.fill).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

/// "Final cut  44 / 50", or a dash when not graded yet.
struct GradePointsCell: View {
    let label: String
    let value: Double?
    let max: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(label, color: Brand.muted, size: 11)
            if let value {
                (Text(GradesPresentation.points(value)).foregroundStyle(Brand.foreground)
                    + Text(" / \(GradesPresentation.points(max))").foregroundStyle(Brand.muted))
                    .font(.mono(18, .medium))
                    .monospacedDigit()
            } else {
                Text("—")
                    .font(.mono(18, .medium))
                    .foregroundStyle(Brand.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: Brand.radius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "\(label): \(GradesPresentation.points($0)) of \(GradesPresentation.points(max))" }
                            ?? "\(label): not graded yet")
    }
}
