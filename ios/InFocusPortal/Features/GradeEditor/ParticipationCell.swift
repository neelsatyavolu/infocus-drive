import SwiftUI

/// One student's score for one class day: Full, or a stepper for docks with a
/// note. Shows what's saved and any score waiting for approval.
struct ParticipationCell: View {
    let student: ParticipationPerson
    let week: ParticipationWeek
    let date: String
    let max: Int
    @Binding var edit: ParticipationEdit

    /// What the cell holds before editing: a pending dock, the saved score, or full marks.
    static func saved(_ userId: String, week: ParticipationWeek, date: String, max: Int) -> ParticipationEdit {
        if let pending = week.pending(userId, date) { return ParticipationEdit(points: pending.points, notes: pending.notes) }
        if let entry = week.entry(userId, date) { return ParticipationEdit(points: entry.points, notes: entry.notes) }
        return ParticipationEdit(points: max, notes: "")
    }

    var body: some View {
        let docked = GradeEditorLogic.isDocked(points: edit.points, max: max)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(student.displayName).font(.lexend(16, .medium, relativeTo: .body))
                Spacer()
                status
            }
            HStack(spacing: 12) {
                Stepper(value: $edit.points, in: 0...max) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(edit.points)").font(.mono(20, .medium))
                        Text("/\(max)").font(.mono(13)).foregroundStyle(Brand.muted)
                    }
                }
                .accessibilityLabel("\(student.displayName) participation")
                .accessibilityValue("\(edit.points) of \(max)")
                Button("Full") { edit = ParticipationEdit(points: max, notes: "") }
                    .buttonStyle(.brandSecondary)
                    .fixedSize()
                    .disabled(edit.points == max && hasScore)
            }
            if docked {
                TextField("Note", text: $edit.notes, axis: .vertical)
                    .font(.small)
                    .lineLimit(1...3)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
            }
        }
        .card(padding: 12)
    }

    /// Saved or waiting for approval (a cell with neither still needs saving).
    private var hasScore: Bool { week.pending(student.id, date) != nil || week.entry(student.id, date) != nil }

    @ViewBuilder private var status: some View {
        if let pending = week.pending(student.id, date) {
            StatusTag(text: "Pending \(pending.points)", tone: .warning)
                .accessibilityLabel("Waiting for approval: \(pending.points) points from \(pending.requestedBy.displayName)")
        } else if week.entry(student.id, date) != nil {
            StatusTag(text: "Saved", tone: .success)
        } else {
            StatusTag(text: "Not entered")
        }
    }
}
