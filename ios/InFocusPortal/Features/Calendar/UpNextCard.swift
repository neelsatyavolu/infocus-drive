import SwiftUI

/// Top of the Calendar tab: the next show as a nameplate, and the person's own next job
/// ("You: Anchor on Wednesday").
struct UpNextCard: View {
    let shows: [CalendarDay]
    let user: PortalUser?
    let today: String

    var body: some View {
        if let next = shows.first {
            NavigationLink(value: Route.calendar(.day(date: next.date))) {
                VStack(alignment: .leading, spacing: 0) {
                    Nameplate(eyebrow: next.date == today ? "Today's show" : "Next show",
                              title: CalendarDates.relative(next.date, today: today) == "Today"
                                  ? CalendarDates.long(next.date)
                                  : "\(CalendarDates.relative(next.date, today: today)) · \(CalendarDates.long(next.date))",
                              subtitle: castLine(next))
                    if let myNext {
                        HStack(spacing: 8) {
                            Image(systemName: "person.wave.2").foregroundStyle(Brand.green).accessibilityHidden(true)
                            Text(myNext).font(.lexend(15, .medium, relativeTo: .body))
                            Spacer()
                        }
                        .padding(16)
                        .background(Brand.greenTint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens that day")
        }
    }

    private func castLine(_ day: CalendarDay) -> String {
        let anchors = day.names(for: "Anchors")
        return anchors.isEmpty ? "Anchors not set yet" : "Anchors: \(anchors.joined(separator: " & "))"
    }

    /// The first upcoming show day with one of the person's jobs on it.
    private var myNext: String? {
        for day in shows {
            if let job = CalendarRoles.mine(on: day, user: user).first {
                return "You: \(job) \(CalendarDates.relative(day.date, today: today).lowercasedIfWeekday)"
            }
        }
        return nil
    }
}

private extension String {
    /// "Today"/"Tomorrow" read naturally mid-sentence; weekday names stay capitalized.
    var lowercasedIfWeekday: String { self == "Today" || self == "Tomorrow" ? lowercased() : "on \(self)" }
}
