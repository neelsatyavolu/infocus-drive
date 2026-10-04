import Foundation

/// `GET api/meetings` (Portal `listMeetings`): live, the next 21 days, and the last 30.
struct MeetingsList: Decodable, Sendable, Equatable {
    var live: [MeetingSummary]
    var upcoming: [MeetingSummary]
    var past: [MeetingSummary]
    var canCreateInviteOnly: Bool

    init(live: [MeetingSummary], upcoming: [MeetingSummary], past: [MeetingSummary], canCreateInviteOnly: Bool = false) {
        self.live = live
        self.upcoming = upcoming
        self.past = past
        self.canCreateInviteOnly = canCreateInviteOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        live = try c.decodeIfPresent([MeetingSummary].self, forKey: .live) ?? []
        upcoming = try c.decodeIfPresent([MeetingSummary].self, forKey: .upcoming) ?? []
        past = try c.decodeIfPresent([MeetingSummary].self, forKey: .past) ?? []
        canCreateInviteOnly = try c.decodeIfPresent(Bool.self, forKey: .canCreateInviteOnly) ?? false
    }

    private enum CodingKeys: String, CodingKey { case live, upcoming, past, canCreateInviteOnly }

    var isEmpty: Bool { live.isEmpty && upcoming.isEmpty && past.isEmpty }
}

/// One meeting row (Portal `MeetingSummary`). Unknown or missing extras fall back
/// to safe defaults so a newer Portal never breaks the list.
struct MeetingSummary: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let startsAt: Date
    let durationMinutes: Int
    /// SCHEDULED, LIVE, ENDED, CANCELED.
    let status: String
    /// OPEN or INVITE_ONLY.
    let access: String
    let inviteeCount: Int
    /// When Join turns on; nil from an older Portal (then 5 minutes before the start).
    let joinOpensAt: Date?
    let isHost: Bool
    let canEdit: Bool
    /// RECORDING, PROCESSING, READY, FAILED, or nil when notes are off.
    let notesStatus: String?

    static let defaultJoinLead: TimeInterval = 5 * 60

    init(id: String, title: String, startsAt: Date, durationMinutes: Int = 60, status: String = "SCHEDULED",
         access: String = "OPEN", inviteeCount: Int = 0, joinOpensAt: Date? = nil, isHost: Bool = false,
         canEdit: Bool = false, notesStatus: String? = nil) {
        self.id = id
        self.title = title
        self.startsAt = startsAt
        self.durationMinutes = durationMinutes
        self.status = status
        self.access = access
        self.inviteeCount = inviteeCount
        self.joinOpensAt = joinOpensAt
        self.isHost = isHost
        self.canEdit = canEdit
        self.notesStatus = notesStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            startsAt: try c.decode(Date.self, forKey: .startsAt),
            durationMinutes: try c.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 60,
            status: try c.decodeIfPresent(String.self, forKey: .status) ?? "SCHEDULED",
            access: try c.decodeIfPresent(String.self, forKey: .access) ?? "OPEN",
            inviteeCount: try c.decodeIfPresent(Int.self, forKey: .inviteeCount) ?? 0,
            joinOpensAt: try c.decodeIfPresent(Date.self, forKey: .joinOpensAt),
            isHost: try c.decodeIfPresent(Bool.self, forKey: .isHost) ?? false,
            canEdit: try c.decodeIfPresent(Bool.self, forKey: .canEdit) ?? false,
            notesStatus: try c.decodeIfPresent(String.self, forKey: .notesStatus))
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startsAt, durationMinutes, status, access, inviteeCount, joinOpensAt, isHost, canEdit, notesStatus
    }

    var isLive: Bool { status == "LIVE" }
    var isInviteOnly: Bool { access == "INVITE_ONLY" }
    var endsAt: Date { startsAt.addingTimeInterval(TimeInterval(durationMinutes) * 60) }
    var opensAt: Date { joinOpensAt ?? startsAt.addingTimeInterval(-Self.defaultJoinLead) }

    /// Whether Join is on, or when it turns on.
    enum JoinState: Equatable {
        case open
        case opensAt(Date)
        case closed
    }

    func joinState(now: Date = Date()) -> JoinState {
        switch status {
        case "LIVE": return .open
        case "SCHEDULED": return now >= opensAt ? .open : .opensAt(opensAt)
        default: return .closed
        }
    }

    /// Notes wording for past meetings.
    var notesLabel: String? {
        switch notesStatus {
        case "READY": "Notes ready"
        case "PROCESSING", "RECORDING": "Notes processing"
        case "FAILED": "Notes failed"
        default: nil
        }
    }
}

/// Upcoming meetings grouped by Pacific calendar day, soonest first.
struct MeetingDay: Identifiable, Equatable {
    let id: String
    let heading: String
    let meetings: [MeetingSummary]
}

enum MeetingDates {
    static let timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current

    static var calendar: Calendar {
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
    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let fullDay = formatter("EEEE MMMM d")
    private static let shortDay = formatter("EEE MMM d")

    /// "9:15 PM" in Pacific time.
    static func clock(_ date: Date) -> String { time.string(from: date) }

    /// "Today", "Tomorrow", else "Wednesday, October 7".
    static func dayHeading(_ date: Date, now: Date = Date()) -> String {
        let cal = calendar
        if cal.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return fullDay.string(from: date)
    }

    /// "Sun Oct 4 · 9:15 PM".
    static func dayAndTime(_ date: Date) -> String {
        "\(shortDay.string(from: date)) · \(time.string(from: date))"
    }

    static func groupByDay(_ meetings: [MeetingSummary], now: Date = Date()) -> [MeetingDay] {
        let sorted = meetings.sorted { $0.startsAt < $1.startsAt }
        var days: [MeetingDay] = []
        for meeting in sorted {
            let key = dayKey.string(from: meeting.startsAt)
            if let last = days.last, last.id == key {
                days[days.count - 1] = MeetingDay(id: key, heading: last.heading, meetings: last.meetings + [meeting])
            } else {
                days.append(MeetingDay(id: key, heading: dayHeading(meeting.startsAt, now: now), meetings: [meeting]))
            }
        }
        return days
    }
}
