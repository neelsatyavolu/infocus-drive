import SwiftUI

/// The Show: the next show days with their cast (anchors, show manager, director) and
/// what airs. Read from the Master Calendar, which everyone can see. Producers run
/// cast and crew in the Portal's The Show page.
struct TheShowView: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    private let store = CalendarStore.shared
    private let today = CalendarDates.todayKey()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Nameplate(eyebrow: "InFocus News", title: "The Show", subtitle: "Who's on the next shows")
                content
                if session.user?.isProducer == true {
                    Button {
                        router.openPortal("show-roles", title: "The Show")
                    } label: {
                        Label("Manage cast in The Show", systemImage: "person.2.badge.gearshape")
                    }
                    .buttonStyle(.brandSecondary)
                }
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle("The Show")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
    }

    private var currentMonth: String { CalendarDates.monthKey(of: today) }

    @ViewBuilder
    private var content: some View {
        let shows = store.upcomingShows(from: today, limit: 10)
        if !shows.isEmpty {
            ForEach(shows) { show in
                NavigationLink(value: Route.calendar(.day(date: show.date))) {
                    ShowCard(show: show, today: today, mine: CalendarRoles.mine(on: show, user: session.user))
                }
                .buttonStyle(.plain)
            }
        } else {
            LoadableView(store.days(currentMonth), retry: { Task { await load(force: true) } }) { _ in
                EmptyStateView(title: "No shows scheduled", message: "Upcoming shows appear here as the calendar fills in.")
            }
        }
    }

    private func load(force: Bool) async {
        let api = CalendarAPI.current(client)
        async let this: Void = store.load(currentMonth, api: api, force: force)
        async let next: Void = store.load(CalendarDates.addMonths(currentMonth, 1), api: api, force: force)
        _ = await (this, next)
    }
}

/// One show day: when, cast, and what airs.
private struct ShowCard: View {
    let show: CalendarDay
    let today: String
    let mine: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(CalendarDates.horizon(show.date, today: today))
                    Text(CalendarDates.long(show.date)).headline(.h3)
                }
                Spacer()
                ForEach(mine, id: \.self) { StatusTag(text: "You: \($0)", tone: .success) }
            }
            castRow("Anchors", show.names(for: "Anchors"), joiner: " & ")
            castRow("Show manager", show.names(for: "Show Manager"), joiner: ", ")
            castRow("Show director", show.names(for: "Show Director"), joiner: ", ")
            if !show.packages.isEmpty {
                castRow("Airing", show.packages.map(\.groupTopic), joiner: " · ")
            } else if let package = show.roles.first(where: { $0.heading.lowercased().hasPrefix("package") })?.lines.first {
                castRow("Package", [package], joiner: "")
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func castRow(_ label: String, _ names: [String], joiner: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.small)
                .foregroundStyle(Brand.muted)
                .frame(width: 104, alignment: .leading)
            Text(names.isEmpty ? "Not set" : names.joined(separator: joiner))
                .font(.lexend(15, names.isEmpty ? .regular : .medium, relativeTo: .body))
                .foregroundStyle(names.isEmpty ? Brand.muted : Brand.foreground)
            Spacer(minLength: 0)
        }
    }
}
