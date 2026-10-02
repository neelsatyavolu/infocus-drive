import SwiftUI

/// Participation week by week: each class day's points and notes (web Participation view).
struct GradesParticipation: View {
    let grades: GradesMe
    @State private var weekIndex: Int?

    var body: some View {
        let weeks = grades.gradebook?.weeks ?? []
        let total = GradesPresentation.participationTotals(grades.estimated)
        let index = min(weekIndex ?? GradesPresentation.currentWeekIndex(weeks, today: GradesPresentation.todayKey()),
                        max(weeks.count - 1, 0))
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Official total")
                    .font(.bodyText)
                    .foregroundStyle(Brand.secondary)
                Spacer()
                Text(total.possible > 0 ? "\(GradesPresentation.points(total.earned)) / \(GradesPresentation.points(total.possible))" : "—")
                    .font(.mono(17, .medium))
                    .monospacedDigit()
            }
            .card()
            .accessibilityElement(children: .combine)

            if weeks.isEmpty {
                EmptyStateView(title: "No weeks yet", message: "Participation shows up once class days are graded.")
            } else {
                weekSwitcher(weeks, index: index)
                WeekCard(week: weeks[index])
            }
        }
    }

    private func weekSwitcher(_ weeks: [GradesMe.Week], index: Int) -> some View {
        HStack(spacing: 8) {
            arrow("chevron.left", label: "Previous week", enabled: index > 0) { weekIndex = index - 1 }
            Menu {
                ForEach(Array(weeks.enumerated()), id: \.element.id) { offset, week in
                    Button(week.label) { weekIndex = offset }
                }
            } label: {
                HStack {
                    Text(weeks[index].label).font(.lexend(15, .medium, relativeTo: .body))
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .foregroundStyle(Brand.foreground)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
            }
            .accessibilityLabel("Week: \(weeks[index].label)")
            arrow("chevron.right", label: "Next week", enabled: index < weeks.count - 1) { weekIndex = index + 1 }
        }
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
        }
        .foregroundStyle(enabled ? Brand.foreground : Brand.muted)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct WeekCard: View {
    let week: GradesMe.Week

    var body: some View {
        let days = week.days.filter { $0.maxPoints > 0 || $0.points != nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(week.label).headline(.h3)
                    Text(week.fullPossible > 0 ? "\(GradesPresentation.points(week.fullPossible)) pts possible" : "No class days")
                        .font(.small)
                        .foregroundStyle(Brand.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    StatusTag(text: week.graded ? "Graded" : "Not graded yet", tone: week.graded ? .success : .neutral)
                    Text(week.graded ? "\(GradesPresentation.points(week.earned)) / \(GradesPresentation.points(week.possible))" : "—")
                        .font(.mono(17, .medium))
                        .monospacedDigit()
                }
            }
            if days.isEmpty {
                Text("No class days this week.")
                    .font(.small)
                    .foregroundStyle(Brand.muted)
            }
            ForEach(days) { day in
                Divider().overlay(Brand.line)
                DayRow(day: day)
            }
        }
        .card()
    }
}

private struct DayRow: View {
    let day: GradesMe.Day

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(day.weekday) · \(String(day.date.suffix(5)))")
                    .font(.mono(13))
                    .foregroundStyle(Brand.secondary)
                Text(GradesPresentation.dayKind(day.kind) + (day.label.isEmpty ? "" : " · \(day.label)"))
                    .font(.small)
                    .foregroundStyle(Brand.muted)
                if !day.notes.isEmpty {
                    Text(day.notes)
                        .font(.small)
                        .foregroundStyle(Brand.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(day.points.map { "\(GradesPresentation.points($0)) / \(GradesPresentation.points(day.maxPoints))" } ?? "—")
                .font(.mono(15, .medium))
                .monospacedDigit()
                .foregroundStyle(day.points == nil ? Brand.muted : Brand.foreground)
        }
        .accessibilityElement(children: .combine)
    }
}
