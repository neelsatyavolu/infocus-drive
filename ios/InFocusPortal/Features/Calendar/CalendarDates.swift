import Foundation

/// `YYYY-MM-DD` / `YYYY-MM` keys in Pacific time, as the Portal stores calendar days.
enum CalendarDates {
    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func todayKey(now: Date = Date()) -> String { formatter("yyyy-MM-dd").string(from: now) }
    static func monthKey(of dateKey: String) -> String { String(dateKey.prefix(7)) }

    static func date(_ key: String) -> Date? {
        formatter(key.count == 7 ? "yyyy-MM" : "yyyy-MM-dd").date(from: key)
    }

    /// `2026-10` + 1 → `2026-11`.
    static func addMonths(_ monthKey: String, _ count: Int) -> String {
        guard let start = date(monthKey), let moved = calendar.date(byAdding: .month, value: count, to: start) else { return monthKey }
        return formatter("yyyy-MM").string(from: moved)
    }

    /// Monday–Friday keys of a month, in order (the calendar has no weekend days).
    static func weekdays(inMonth monthKey: String) -> [String] {
        guard let start = date(monthKey), let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let keys = formatter("yyyy-MM-dd")
        return range.compactMap { day -> String? in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: start) else { return nil }
            let weekday = calendar.component(.weekday, from: date)
            return (2...6).contains(weekday) ? keys.string(from: date) : nil
        }
    }

    /// 1 = Sunday … 7 = Saturday.
    static func weekday(_ key: String) -> Int {
        date(key).map { calendar.component(.weekday, from: $0) } ?? 0
    }

    /// "Wednesday, October 7".
    static func long(_ key: String) -> String { date(key).map { formatter("EEEE, MMMM d").string(from: $0) } ?? key }
    /// "Wed".
    static func weekdayShort(_ key: String) -> String { date(key).map { formatter("EEE").string(from: $0) } ?? "" }
    /// "7".
    static func dayNumber(_ key: String) -> String { date(key).map { formatter("d").string(from: $0) } ?? "" }
    /// "October 2026".
    static func monthTitle(_ monthKey: String) -> String { date(monthKey).map { formatter("MMMM yyyy").string(from: $0) } ?? monthKey }

    /// How far off a day is, for eyebrows above a full date: Today, Tomorrow, This week, Next week, Later.
    static func horizon(_ key: String, today: String = todayKey()) -> String {
        guard let day = date(key), let now = date(today),
              let offset = calendar.dateComponents([.day], from: now, to: day).day else { return "" }
        switch offset {
        case ..<0: return "Past"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let week = { (date: Date) in calendar.dateInterval(of: .weekOfYear, for: date)?.start }
            if week(day) == week(now) { return "This week" }
            if let start = week(now), let next = calendar.date(byAdding: .day, value: 7, to: start), week(day) == next {
                return "Next week"
            }
            return "Later"
        }
    }

    /// "Today", "Tomorrow", or the weekday name within a week; otherwise "Wed, Oct 7".
    static func relative(_ key: String, today: String = todayKey()) -> String {
        guard let day = date(key), let now = date(today),
              let offset = calendar.dateComponents([.day], from: now, to: day).day else { return key }
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return formatter("EEEE").string(from: day)
        default: return formatter("EEE, MMM d").string(from: day)
        }
    }
}
