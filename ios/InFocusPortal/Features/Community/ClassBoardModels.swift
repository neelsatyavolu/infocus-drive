import Foundation

/// `GET api/class-board`: the classroom display's data (the Portal's `ClassBoardModel`). Every
/// field is a string, number or boolean; tones, dots and day kinds stay strings so a new value
/// from the Portal shows as neutral instead of failing the whole board.
struct ClassBoard: Decodable, Sendable, Equatable {
    struct ClassSession: Decodable, Sendable, Equatable {
        /// "2026-10-05" (Pacific).
        let date: String
        let startsAt: Date
        let endsAt: Date
    }

    struct Deadline: Decodable, Identifiable, Sendable, Equatable {
        let id: String
        let cycleNumber: Int
        let label: String
        let dateKey: String
        let daysUntil: Int
        let when: String
        /// The next step for this stage ("Upload your Initial Cut").
        let focus: String
    }

    struct Gate: Decodable, Identifiable, Sendable, Equatable {
        /// `pitching`, `brainstorming`, `a-roll`, `initial-stage-1…3`, `final-cut`.
        let key: String
        let label: String
        /// "Oct 14", or nil when the cycle has no date for it.
        let dateLabel: String?

        var id: String { key }
    }

    struct Lane: Decodable, Identifiable, Sendable, Equatable {
        let id: String
        let place: Int
        let topic: String
        /// Members' first names and the assigned producer.
        let detail: String
        let `extension`: Bool
        let extensionDays: Int
        let statusLabel: String
        /// `neutral`, `warn`, `review`, `danger` or `approved`.
        let tone: String
        let packageOfCycle: Bool
        let doneCount: Int
        /// One per gate: `done`, `current` or `upcoming`.
        let dots: [String]
        let segments: [String]
    }

    struct Livestream: Decodable, Identifiable, Sendable, Equatable {
        let id: String
        let dateKey: String
        let dayLabel: String
        let timeLabel: String
        let started: Bool
        let title: String
        let `where`: String
        let crew: String
        /// "Full", "1 open", "3 open".
        let openLabel: String
        /// `full`, `one` or `open`.
        let tone: String
        let availability: String
    }

    struct Day: Decodable, Identifiable, Sendable, Equatable {
        let date: String
        /// "MON".
        let weekday: String
        let dayNum: String
        /// `PA`, `SHOW`, `NONE` or `HOLIDAY`.
        let kind: String
        let kindLabel: String
        /// "Anchors  Abby · Otto" (role, two spaces, names) or free text.
        let lines: [String]

        var id: String { date }
        var isHoliday: Bool { kind == "HOLIDAY" }
    }

    let classSessions: [ClassSession]
    let deadlines: [Deadline]
    let generatedAt: Date
    let cycleNumber: Int
    let cycleFocus: String
    let gates: [Gate]
    let lanes: [Lane]
    let livestreams: [Livestream]
    let days: [Day]
}

/// Words, tags and times for the Class Board, matching the web board.
enum ClassBoardFormat {
    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    /// The short gate names the web uses over the dots.
    static func gateShortLabel(_ gate: ClassBoard.Gate) -> String {
        switch gate.key {
        case "pitching": "Pitch"
        case "brainstorming": "Contact"
        case "a-roll": "A/B"
        case "initial-stage-1": "Init 1"
        case "initial-stage-2": "Init 2"
        case "initial-stage-3": "Init 3"
        case "final-cut": "Final"
        default: gate.label
        }
    }

    /// "Today", "in 3d" (and "2d ago", which the board never lists).
    static func relativeDays(_ days: Int) -> String {
        if days == 0 { return "Today" }
        return days > 0 ? "in \(days)d" : "\(-days)d ago"
    }

    /// Amber for today and tomorrow, danger once past, calm after that.
    static func dueTone(_ days: Int) -> StatusTag.Tone {
        if days < 0 { return .danger }
        return days <= 1 ? .warning : .neutral
    }

    /// A lane's status tone (Groups tile tones).
    static func laneTone(_ tone: String) -> StatusTag.Tone {
        switch tone {
        case "warn": .warning
        case "danger": .danger
        case "approved": .success
        default: .neutral
        }
    }

    /// Any open crew slot is a call for crew (amber); a full crew is calm.
    static func capacityTone(_ tone: String) -> StatusTag.Tone {
        tone == "full" ? .neutral : .warning
    }

    /// "10 Day Extension", or "Extension" without a day count.
    static func extensionLabel(_ days: Int) -> String {
        days > 0 ? "\(days) Day Extension" : "Extension"
    }

    /// One tag per day. A holiday always reads "No school"; its own name moves into the lines.
    static func dayTag(_ day: ClassBoard.Day) -> (label: String, tone: StatusTag.Tone, note: String?) {
        let label = day.kindLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        switch day.kind {
        case "HOLIDAY":
            let named = !label.isEmpty && label.lowercased() != "no school"
            return ("No school", .neutral, named ? label : nil)
        case "SHOW": return (label, .success, nil)
        case "PA": return (label, .warning, nil)
        default: return (label, .neutral, nil)
        }
    }

    /// The day's lines, with a holiday's name first.
    static func dayLines(_ day: ClassBoard.Day) -> [String] {
        dayTag(day).note.map { [$0] + day.lines } ?? day.lines
    }

    private static let roles: Set<String> = [
        "Anchors", "Manager", "Announcers", "On air",
        "Filmers", "Brunch Filmers", "Lunch Filmers", "Night Rally Filmers", "Editors"
    ]

    /// Splits "Anchors  Abby · Otto" into its role and names. Only a known role is split, so a
    /// class day's own label that happens to hold two spaces stays plain.
    static func splitRoleLine(_ line: String) -> (role: String?, value: String) {
        guard let range = line.range(of: "  "), range.lowerBound > line.startIndex else {
            return (nil, line.trimmingCharacters(in: .whitespaces))
        }
        let role = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard roles.contains(role) else { return (nil, line.trimmingCharacters(in: .whitespaces)) }
        return (role, line[range.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    /// "Oct 17" for a deadline's day.
    static func shortDate(_ dateKey: String) -> String {
        guard let date = utcDay(dateKey) else { return dateKey }
        return format(date, "MMM d", zone: TimeZone(identifier: "UTC")!)
    }

    /// ("THU", "15") for a livestream's day.
    static func weekdayAndDay(_ dateKey: String) -> (weekday: String, day: String) {
        guard let date = utcDay(dateKey) else { return ("", dateKey) }
        let utc = TimeZone(identifier: "UTC")!
        return (format(date, "EEE", zone: utc).uppercased(), format(date, "d", zone: utc))
    }

    /// "10:42 AM", Pacific.
    static func time(_ date: Date) -> String { format(date, "h:mm a", zone: timeZone) }

    /// "Thu, Oct 15", Pacific.
    static func today(_ date: Date) -> String { format(date, "EEE, MMM d", zone: timeZone) }

    /// "2026-10-15", Pacific.
    static func dateKey(_ date: Date) -> String { format(date, "yyyy-MM-dd", zone: timeZone) }

    /// The nameplate's focus. During Period 1: the next step for the nearest deadline and the time
    /// left in class. Otherwise: the soonest deadline's next step ("Up next"). Nil with no deadlines
    /// outside class.
    struct Focus: Equatable {
        let eyebrow: String
        let text: String
        let detail: String
        /// "12:05" left in class, during Period 1 only.
        let countdown: String?
        /// Under ten minutes left (amber).
        let ending: Bool
        /// "in 2d" beside Up next, toned like Due next.
        let tag: String?
        let tone: StatusTag.Tone
    }

    static func focus(_ board: ClassBoard, now: Date) -> Focus? {
        let today = dateKey(now)
        let day = board.days.first { $0.date == today }
        if let day, !day.isHoliday,
           let session = board.classSessions.first(where: { $0.date == today && $0.startsAt <= now && now < $0.endsAt }) {
            let deadline = board.deadlines.filter { $0.dateKey >= today }
                .min { ($0.dateKey, $0.cycleNumber) < ($1.dateKey, $1.cycleNumber) }
            let seconds = Int(session.endsAt.timeIntervalSince(now).rounded(.up))
            let detail: String
            if let deadline {
                let days = daysBetween(today, deadline.dateKey)
                let due = days == 0 ? "Due today" : days == 1 ? "Due tomorrow" : "Due in \(days)d"
                detail = "Cycle \(deadline.cycleNumber) · \(due)"
            } else {
                detail = "Period 1 · Class focus"
            }
            return Focus(eyebrow: "Class focus", text: deadline?.focus ?? "Plan your next package steps", detail: detail,
                         countdown: "\(seconds / 60):" + String(format: "%02d", seconds % 60),
                         ending: seconds <= 600, tag: nil, tone: .neutral)
        }
        guard let next = board.deadlines.first else { return nil }
        return Focus(eyebrow: "Up next", text: next.focus, detail: "\(next.label) · Cycle \(next.cycleNumber)",
                     countdown: nil, ending: false, tag: relativeDays(next.daysUntil), tone: dueTone(next.daysUntil))
    }

    private static func daysBetween(_ from: String, _ to: String) -> Int {
        guard let start = utcDay(from), let end = utcDay(to) else { return 0 }
        return Int((end.timeIntervalSince(start) / 86_400).rounded())
    }

    private static func utcDay(_ key: String) -> Date? {
        guard IdeasPage.validDate(key) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }

    private static func format(_ date: Date, _ pattern: String, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
