import Foundation

/// Date wording for chats, gear and livestreams. Pacific time, like the Portal.
enum FeatureDates {
    static let timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let time = formatter("h:mm a")
    private static let weekday = formatter("EEE")
    private static let monthDay = formatter("MMM d")
    private static let weekdayMonthDay = formatter("EEE MMM d")
    private static let full = formatter("EEEE MMMM d")

    /// Inbox row: "3:42 PM" today, "Yesterday", "Tue" this week, else "Sep 28".
    static func inbox(_ date: Date, now: Date = Date()) -> String {
        let cal = calendar
        if cal.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day,
           days < 7, days >= 0 {
            return weekday.string(from: date)
        }
        return monthDay.string(from: date)
    }

    /// Chat day separator: "Today", "Yesterday", else "Friday, September 25".
    static func dayHeading(_ date: Date, now: Date = Date()) -> String {
        let cal = calendar
        if cal.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return full.string(from: date)
    }

    static func sameDay(_ a: Date, _ b: Date) -> Bool { calendar.isDate(a, inSameDayAs: b) }

    static func clock(_ date: Date) -> String { time.string(from: date) }

    /// "Tue Oct 6 · 4:10 PM".
    static func dayAndTime(_ date: Date) -> String {
        "\(weekdayMonthDay.string(from: date)) · \(time.string(from: date))"
    }

    static func shortDay(_ date: Date) -> String { monthDay.string(from: date) }

    /// The livestream schedule's split: anything before today's start is "earlier".
    static func isBeforeToday(_ date: Date, now: Date = Date()) -> Bool {
        date < calendar.startOfDay(for: now)
    }
}
