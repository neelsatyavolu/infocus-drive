import Foundation

/// The Portal's Thanksgiving season (`src/lib/thanksgiving.ts`): every day of November in local
/// time the app wears harvest colors, Home gets its visitors, and More → Class has the
/// Leaderboard. Each device can turn the theme or the giant turkey off (Settings → Appearance).
enum HarvestSeason {
    /// November.
    static let month = 11

    static func isSeason(_ now: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.month, from: now) == month
    }

    /// On in season unless this device turned it off.
    static func isOn(off: Bool, now: Date, calendar: Calendar = .current) -> Bool {
        !off && isSeason(now, calendar: calendar)
    }

    /// Whether this device still needs this year's welcome (`stored` is the year it last saw it).
    static func needsWelcome(stored: String?, now: Date, calendar: Calendar = .current) -> Bool {
        stored != String(calendar.component(.year, from: now))
    }

    /// The next local midnight after `now`, when the season can start or end.
    static func nextMidnight(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                          matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
    }

    /// Strutting-turkey taps that earn a pardon (`PARDON_CLICKS`).
    static let pardonTaps = 5
}
