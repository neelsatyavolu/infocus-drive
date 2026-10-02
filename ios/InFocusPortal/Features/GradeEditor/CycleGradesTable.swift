import SwiftUI

/// The spreadsheet layout for iPad and landscape: one row per person with every
/// column of the web table, scrolling sideways inside its own container.
struct CycleGradesTable: View {
    let cycleNumber: Int
    let rows: [CycleGradeRow]

    private static let columns: [(String, CGFloat)] = [
        ("Name", 200), ("Pitching", 72), ("PoC", 60), ("A/B", 60), ("Initial", 64),
        ("Final Cut", 96), ("Turned in", 104), ("Feedback", 84), ("Status", 116),
    ]

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Self.columns, id: \.0) { title, width in
                        Text(title.uppercased())
                            .font(.lexend(11, .medium, relativeTo: .caption2))
                            .tracking(1.2)
                            .foregroundStyle(Brand.muted)
                            .frame(width: width, alignment: .leading)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .accessibilityHidden(true)
                Rectangle().fill(Brand.line).frame(height: 1)
                ForEach(rows) { row in
                    NavigationLink(value: Route.gradeEditor(.cycleStudent(cycle: cycleNumber, userId: row.userId))) {
                        line(row)
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(Brand.line).frame(height: 1)
                }
            }
            .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
        }
    }

    private func line(_ row: CycleGradeRow) -> some View {
        HStack(spacing: 0) {
            Text(row.displayName).font(.lexend(15, .medium, relativeTo: .body)).lineLimit(1)
                .frame(width: Self.columns[0].1, alignment: .leading)
            ForEach(Array(CheckInStage.allCases.enumerated()), id: \.element) { index, stage in
                Text(row.checkInScores?[stage]?.label ?? "N/A")
                    .font(.mono(13))
                    .foregroundStyle(row.checkInScores?[stage] == nil ? Brand.muted : Brand.foreground)
                    .frame(width: Self.columns[index + 1].1, alignment: .leading)
            }
            Text(row.finalCutState == .exempt ? "Exempt" : "\(GradeEditorLogic.points(row.effortPoints))/50")
                .font(.mono(14, .medium))
                .frame(width: Self.columns[5].1, alignment: .leading)
            Text(row.turnedInDate.map(GradeEditorLogic.dayLabel) ?? "—")
                .font(.mono(13))
                .frame(width: Self.columns[6].1, alignment: .leading)
            Text(row.feedback.isEmpty ? "—" : "Written")
                .font(.small)
                .foregroundStyle(row.feedback.isEmpty ? Brand.muted : Brand.green)
                .frame(width: Self.columns[7].1, alignment: .leading)
            GradeStatusTag(row: row)
                .frame(width: Self.columns[8].1, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
