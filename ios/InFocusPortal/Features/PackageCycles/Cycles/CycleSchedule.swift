import Foundation

/// Stage-date status for the Package Cycles page. A cycle date closes at 11:59 PM Pacific
/// on that day (Portal `src/lib/deadlines.ts`), never at midnight UTC.
enum CycleSchedule {
    static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    /// One-off Final Cut closes, keyed by the due date (the Portal's FINAL_CUT_CLOSE_OVERRIDES).
    static let finalCutOverrides: [String: String] = ["2026-09-29": "2026-09-30T09:00:00.000Z"]

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        return calendar
    }

    /// The Pacific calendar day of a `YYYY-MM-DD` key, or nil if it isn't one.
    static func day(_ key: String?) -> DateComponents? {
        guard let key, key.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return components
    }

    /// The last moment a stage date is open: 11:59:59 PM Pacific that day (or a Final Cut override).
    static func closesAt(_ key: String, stage: RosterStage) -> Date? {
        if stage == .finalCut, let override = finalCutOverrides[key] { return PortalJSON.date(from: override) }
        guard let components = day(key), let start = calendar.date(from: components),
              let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return next.addingTimeInterval(-0.001)
    }

    static func passed(_ key: String?, stage: RosterStage, now: Date) -> Bool {
        guard let key, let closes = closesAt(key, stage: stage) else { return false }
        return now > closes
    }

    enum Status: Equatable {
        case tbd
        case completed
        case dueToday
        case inDays(Int)
    }

    static func status(_ key: String?, stage: RosterStage, now: Date) -> Status {
        guard let key, let components = day(key), let target = calendar.date(from: components) else { return .tbd }
        if passed(key, stage: stage, now: now) { return .completed }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        return days <= 0 ? .dueToday : .inDays(days)
    }

    enum Section: Int, Comparable {
        case active, planned, closed
        static func < (lhs: Section, rhs: Section) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .active: "Active"
            case .planned: "Planned"
            case .closed: "Closed"
            }
        }
    }

    /// Active (the first open cycle), then Planned, then Closed (Final Cut passed), each by number.
    static func ordered(_ cycles: [CycleDates], now: Date) -> [(cycle: CycleDates, section: Section)] {
        let byNumber = cycles.sorted { $0.cycleNumber < $1.cycleNumber }
        let open = byNumber.filter { !passed($0.finalCutDate, stage: .finalCut, now: now) }
        let closed = byNumber.filter { passed($0.finalCutDate, stage: .finalCut, now: now) }
        return open.enumerated().map { ($0.element, $0.offset == 0 ? Section.active : .planned) }
            + closed.map { ($0, .closed) }
    }

    /// The next stage whose date hasn't closed yet.
    static func nextStage(_ cycle: CycleDates, now: Date) -> (stage: RosterStage, date: String)? {
        RosterStage.allCases.lazy.compactMap { stage in
            cycle.date(stage).flatMap { passed($0, stage: stage, now: now) ? nil : (stage, $0) }
        }.first
    }

    /// "Cycle 2 · October" from the brainstorming date (or Final Cut), like the web.
    static func name(_ cycle: CycleDates) -> String {
        guard let components = day(cycle.proofOfContactDate ?? cycle.finalCutDate),
              let date = calendar.date(from: components) else { return "Cycle \(cycle.cycleNumber)" }
        return "Cycle \(cycle.cycleNumber) · \(monthFormatter.string(from: date))"
    }

    /// "Oct 7, 2026" for a date key.
    static func display(_ key: String?) -> String {
        guard let components = day(key), let date = calendar.date(from: components) else { return "TBD" }
        return dayFormatter.string(from: date)
    }

    /// A date key for a picked date (its Pacific day).
    static func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Noon Pacific on a date key, for date pickers.
    static func pickerDate(_ key: String?) -> Date? {
        guard var components = day(key) else { return nil }
        components.hour = 12
        return calendar.date(from: components)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL"
        formatter.timeZone = pacific
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = pacific
        return formatter
    }()
}
