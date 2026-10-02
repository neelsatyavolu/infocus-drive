import SwiftUI

/// Calendar tab: what's next for you, The Show and announcements, then the month as an
/// agenda (phone-first) or a Monday–Friday grid. Days open their detail.
struct CalendarTab: View {
    enum Mode: String, CaseIterable { case agenda = "Agenda", month = "Month" }

    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @Environment(BadgeCenter.self) private var badges
    @Environment(Router.self) private var router

    @State private var monthKey = CalendarDates.monthKey(of: CalendarDates.todayKey())
    @State private var mode: Mode = .agenda
    private let store = CalendarStore.shared
    private let feed = AnnouncementsStore.shared
    private let today = CalendarDates.todayKey()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                UpNextCard(shows: store.upcomingShows(from: today, limit: 3), user: session.user, today: today)
                quickLinks
                monthHeader
                LoadableView(store.days(monthKey), retry: { Task { await load(force: true) } }) { days in
                    switch mode {
                    case .agenda: agenda(days)
                    case .month: MonthGrid(monthKey: monthKey, days: days, today: today, user: session.user)
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle("Calendar")
        .refreshable { await load(force: true) }
        .task {
            await load(force: false)
            #if DEBUG
            // Screenshots: `-InFocusStubSession student -InFocusCalendarDay 2026-10-07`, `-InFocusCalendarMode month`.
            if UserDefaults.standard.string(forKey: "InFocusCalendarMode") == "month" { mode = .month }
            if let day = UserDefaults.standard.string(forKey: "InFocusCalendarDay") {
                router.push(.calendar(.day(date: day)))
            }
            #endif
        }
        .task(id: monthKey) { await store.load(monthKey, api: api) }
        .onChange(of: feed.unreadCount) { _, count in badges.set(count, for: .calendar) }
    }

    private var api: CalendarAPI { CalendarAPI.current(client) }

    private func load(force: Bool) async {
        if let email = session.user?.email {
            store.reset(for: email)
            feed.reset(for: email)
        }
        let current = CalendarDates.monthKey(of: today)
        async let thisMonth: Void = store.load(current, api: api, force: force)
        async let nextMonth: Void = store.load(CalendarDates.addMonths(current, 1), api: api, force: force)
        async let shown: Void = store.load(monthKey, api: api, force: force)
        async let announcements: Void = feed.load(api: api, force: force)
        _ = await (thisMonth, nextMonth, shown, announcements)
        badges.set(feed.unreadCount, for: .calendar)
    }

    private var quickLinks: some View {
        VStack(spacing: 0) {
            QuickLink(title: "The Show", detail: "Upcoming shows and who's on them", systemImage: "tv", route: .calendar(.theShow))
            Divider().overlay(Brand.line)
            QuickLink(title: "Announcements",
                      detail: feed.unreadCount > 0 ? "\(feed.unreadCount) unread" : "Class announcements",
                      systemImage: "megaphone", route: .announcements(.feed), badge: feed.unreadCount)
        }
        .card(padding: 0)
    }

    private var monthHeader: some View {
        VStack(spacing: 12) {
            HStack {
                monthButton("chevron.left", label: "Previous month", offset: -1)
                Spacer()
                Text(CalendarDates.monthTitle(monthKey)).headline(.h3)
                Spacer()
                monthButton("chevron.right", label: "Next month", offset: 1)
            }
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func monthButton(_ systemImage: String, label: String, offset: Int) -> some View {
        Button {
            monthKey = CalendarDates.addMonths(monthKey, offset)
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .foregroundStyle(Brand.green)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func agenda(_ days: [CalendarDay]) -> some View {
        // This month starts at today; other months show every school day.
        let shown = monthKey == CalendarDates.monthKey(of: today) ? days.filter { $0.date >= today } : days
        if shown.isEmpty {
            EmptyStateView(title: "No more school days", message: "Pick the next month to keep going.")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(shown) { day in
                    NavigationLink(value: Route.calendar(.day(date: day.date))) {
                        CalendarDayRow(day: day, mine: CalendarRoles.mine(on: day, user: session.user), today: today)
                    }
                    .buttonStyle(.plain)
                    if day.id != shown.last?.id { Divider().overlay(Brand.line) }
                }
            }
            .padding(.horizontal, 16)
            .card(padding: 0)
        }
    }
}

/// A row that opens another Calendar screen.
private struct QuickLink: View {
    let title: String
    let detail: String
    let systemImage: String
    let route: Route
    var badge = 0

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Brand.green)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.lexend(16, .medium, relativeTo: .body)).foregroundStyle(Brand.foreground)
                    Text(detail).font(.small).foregroundStyle(Brand.muted)
                }
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.mono(13, .medium))
                        .foregroundStyle(Brand.onBrand)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Brand.fill, in: RoundedRectangle(cornerRadius: Brand.tagRadius))
                        .accessibilityLabel("\(badge) unread")
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
