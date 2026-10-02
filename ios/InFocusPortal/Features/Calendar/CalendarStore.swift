import Foundation
import Observation

/// Master Calendar months, cached for the whole Calendar tab (the day and Show screens
/// reuse what the tab loaded). Starts over when someone else signs in.
@MainActor @Observable
final class CalendarStore {
    static let shared = CalendarStore()

    private(set) var months: [String: Loadable<CalendarMonth>] = [:]
    private var owner: String?

    func reset(for email: String) {
        guard owner != email else { return }
        owner = email
        months = [:]
    }

    func load(_ monthKey: String, api: CalendarAPI, force: Bool = false) async {
        if !force, months[monthKey]?.value != nil || months[monthKey]?.isLoading == true { return }
        if months[monthKey]?.value == nil { months[monthKey] = .loading }
        do {
            months[monthKey] = .loaded(try await api.month(monthKey))
        } catch {
            if months[monthKey]?.value == nil { months[monthKey] = .failed(Loadable<CalendarMonth>.message(for: error)) }
        }
    }

    func days(_ monthKey: String) -> Loadable<[CalendarDay]> {
        switch months[monthKey] ?? .idle {
        case .idle: .idle
        case .loading: .loading
        case .failed(let message): .failed(message)
        case .loaded(let month): .loaded(Self.days(from: month))
        }
    }

    func day(_ dateKey: String) -> CalendarDay? {
        months[CalendarDates.monthKey(of: dateKey)]?.value.flatMap { Self.days(from: $0).first { $0.date == dateKey } }
    }

    /// Show days from `today` on, across the months loaded so far.
    func upcomingShows(from today: String, limit: Int = 8) -> [CalendarDay] {
        months.values
            .compactMap(\.value)
            .flatMap(Self.days(from:))
            .filter { $0.kind == .show && $0.date >= today }
            .sorted { $0.date < $1.date }
            .prefix(limit)
            .map { $0 }
    }

    func canEdit(_ monthKey: String) -> Bool { months[monthKey]?.value?.canEdit ?? false }

    func month(_ monthKey: String) -> CalendarMonth? { months[monthKey]?.value }

    /// A producer's save: show the cell the Portal stored right away (a reload follows).
    func apply(content: String, for date: String) {
        let key = CalendarDates.monthKey(of: date)
        guard let month = months[key]?.value else { return }
        months[key] = .loaded(month.replacing(date, content: content))
    }

    func apply(manager: ShowManagerResult, for date: String) {
        let key = CalendarDates.monthKey(of: date)
        guard var month = months[key]?.value else { return }
        if let content = manager.content { month = month.replacing(date, content: content) }
        month.showManagers[date] = .init(name: manager.name, source: manager.source)
        months[key] = .loaded(month)
    }

    /// The month's school days with their cell content parsed, the resolved show manager
    /// (the Portal's rotation unless the cell names one) and the packages queued to air.
    nonisolated static func days(from month: CalendarMonth) -> [CalendarDay] {
        let entries = Dictionary(month.entries.map { ($0.date, $0.content) }, uniquingKeysWith: { first, _ in first })
        return month.schedule.map { day in
            let parsed = DayContent.parse(entries[day.date] ?? "")
            var roles = parsed.sections.filter { !$0.lines.isEmpty }
            if day.kind == .show, let manager = month.showManagers[day.date]?.name, !manager.isEmpty,
               !roles.contains(where: { $0.heading == "Show Manager" }) {
                roles.append(DayContent.Section(heading: "Show Manager", lines: [manager], isPeople: true))
            }
            return CalendarDay(date: day.date, kind: day.kind, label: day.label, roles: roles, notes: parsed.notes,
                               packages: month.queuedPackages.filter { $0.date == day.date })
        }
    }
}

/// Which jobs on a day are the signed-in person's ("Anchor", "Show manager").
enum CalendarRoles {
    private static let titles = [
        "anchors": "Anchor", "show manager": "Show manager", "show director": "Show director",
        "pa announcers": "PA announcer", "editors": "Editor", "filmers": "Filmer",
        "brunch filmers": "Brunch filmer", "lunch filmers": "Lunch filmer", "night rally filmers": "Night rally filmer",
    ]

    /// The calendar writes first names (or full names when two people share one) and nicknames.
    static func names(for user: PortalUser) -> Set<String> {
        var names: Set<String> = [user.name, user.displayName]
        if let first = user.name.split(separator: " ").first { names.insert(String(first)) }
        if let nickname = user.nickname, !nickname.isEmpty { names.insert(nickname) }
        return Set(names.map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    static func mine(on day: CalendarDay, user: PortalUser?) -> [String] {
        guard let user else { return [] }
        let me = names(for: user)
        return day.roles.compactMap { section in
            section.names.contains { me.contains($0.lowercased()) } ? titles[section.heading.lowercased()] ?? section.heading : nil
        }
    }
}
