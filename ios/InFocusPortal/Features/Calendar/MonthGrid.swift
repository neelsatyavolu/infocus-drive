import SwiftUI

/// A Monday–Friday month grid. Each cell says what kind of day it is in words
/// (SHOW, PA, OFF), marks the person's own days, and opens the day.
struct MonthGrid: View {
    let monthKey: String
    let days: [CalendarDay]
    let today: String
    let user: PortalUser?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(["Mon", "Tue", "Wed", "Thu", "Fri"], id: \.self) { name in
                    Text(name.uppercased())
                        .font(.lexend(11, .medium, relativeTo: .caption2))
                        .tracking(1.2)
                        .foregroundStyle(Brand.muted)
                        .accessibilityHidden(true)
                }
                ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.frame(height: 64) }
                ForEach(days) { day in
                    NavigationLink(value: Route.calendar(.day(date: day.date))) {
                        DayCell(day: day, isToday: day.date == today, mine: !CalendarRoles.mine(on: day, user: user).isEmpty)
                    }
                    .buttonStyle(.plain)
                }
            }
            legend
        }
    }

    /// Weekday columns before the 1st (Monday = 0).
    private var leadingBlanks: Int {
        guard let first = days.first else { return 0 }
        return max(0, min(4, CalendarDates.weekday(first.date) - 2))
    }

    private var legend: some View {
        Label("You're on this day", systemImage: "person.fill")
        .font(.small)
        .foregroundStyle(Brand.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DayCell: View {
    let day: CalendarDay
    let isToday: Bool
    let mine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(CalendarDates.dayNumber(day.date))
                    .font(.lexend(16, .semibold, relativeTo: .body))
                Spacer(minLength: 0)
                if mine {
                    Image(systemName: "person.fill").font(.caption2).foregroundStyle(Brand.green)
                }
            }
            Spacer(minLength: 0)
            if let word {
                Text(word)
                    .font(.lexend(10, .medium, relativeTo: .caption2))
                    .tracking(1)
                    .foregroundStyle(day.kind == .show ? Brand.onBrand : Brand.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(day.kind == .show ? Brand.fill : Brand.raised, in: RoundedRectangle(cornerRadius: Brand.tagRadius))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(day.kind == .holiday ? Brand.background : Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(isToday ? Brand.green : Brand.line, lineWidth: isToday ? 2 : 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var word: String? {
        switch day.kind {
        case .show: "SHOW"
        case .pa: "PA"
        case .holiday: "OFF"
        case .none: nil
        }
    }

    private var accessibility: String {
        var parts = [CalendarDates.long(day.date), day.kind.tag]
        if isToday { parts.insert("Today", at: 0) }
        if mine { parts.append("You're on this day") }
        if !day.label.isEmpty { parts.append(day.label) }
        return parts.joined(separator: ", ")
    }
}
