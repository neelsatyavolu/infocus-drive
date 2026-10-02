import SwiftUI

/// One school day: kind, who's anchoring / on PA / managing, packages airing, notes.
/// Producers can edit it in the Portal's Master Calendar.
struct DayDetailView: View {
    let date: String

    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    private let store = CalendarStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LoadableView(state, retry: { Task { await load(force: true) } }) { day in
                    if let day { content(day) } else {
                        EmptyStateView(title: "No school this day", message: "There's nothing on the calendar for this date.")
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle(CalendarDates.weekdayShort(date) + " " + CalendarDates.dayNumber(date))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
    }

    private var monthKey: String { CalendarDates.monthKey(of: date) }

    /// The day once its month is loaded (nil: a weekend or a date outside the calendar).
    private var state: Loadable<CalendarDay?> {
        switch store.days(monthKey) {
        case .idle: .idle
        case .loading: .loading
        case .failed(let message): .failed(message)
        case .loaded(let days): .loaded(days.first { $0.date == date })
        }
    }

    private func load(force: Bool) async {
        await store.load(monthKey, api: CalendarAPI.current(client), force: force)
    }

    @ViewBuilder
    private func content(_ day: CalendarDay) -> some View {
        Nameplate(eyebrow: day.kind == .show ? "Show day" : day.kind.tag, title: CalendarDates.long(day.date),
                  subtitle: day.label.isEmpty ? nil : day.label) {
            DayKindTag(kind: day.kind)
        }

        if !day.roles.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(day.roles, id: \.heading) { section in
                    RoleBlock(section: section, mine: isMine(section))
                }
            }
            .card()
        } else if day.kind == .show || day.kind == .pa {
            EmptyStateView(title: "Not set yet", message: day.kind == .show
                ? "Anchors and the crew appear here once producers fill in the day."
                : "PA announcers appear here once producers fill in the day.")
        }

        if !day.packages.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Airing", color: Brand.muted)
                ForEach(day.packages, id: \.id) { package in
                    HStack {
                        Text(package.groupTopic).font(.lexend(16, .medium, relativeTo: .body))
                        Spacer()
                        Text(package.custom ? "Custom" : "Cycle \(package.cycleNumber)").font(.small).foregroundStyle(Brand.muted)
                    }
                }
            }
            .card()
        }

        if !day.notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Notes", color: Brand.muted)
                ForEach(day.notes, id: \.self) { Text($0).font(.bodyText) }
            }
            .card()
        }

        if store.canEdit(monthKey) {
            Button {
                router.openPortal("master-calendar?date=\(day.date)", title: "Master Calendar")
            } label: {
                Label("Edit in Master Calendar", systemImage: "square.and.pencil")
            }
            .buttonStyle(.brandSecondary)
        }
    }

    private func isMine(_ section: DayContent.Section) -> Bool {
        guard let user = session.user else { return false }
        let me = CalendarRoles.names(for: user)
        return section.names.contains { me.contains($0.lowercased()) }
    }
}
