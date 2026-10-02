import Foundation

/// `GET api/master-calendar?month=YYYY-MM` (src/server/master-calendar-data.ts). Date keys stay strings.
struct CalendarMonth: Decodable, Sendable, Equatable {
    struct Entry: Decodable, Sendable, Equatable {
        let date: String
        let content: String
    }

    struct ScheduleDay: Decodable, Sendable, Equatable {
        let date: String
        let kind: DayKind
        let label: String
    }

    struct QueuedPackage: Decodable, Sendable, Equatable {
        let id: String
        let groupTopic: String
        let cycleNumber: Int
        let custom: Bool
        let date: String?
    }

    struct ShowManager: Decodable, Sendable, Equatable {
        let name: String
        /// "rotation" (the Portal's default order) or "manual" (a producer picked someone).
        var source: String? = nil

        var isManual: Bool { source == "manual" }
    }

    /// A Spirit Week day: the dress-up theme and the crew lists producers fill.
    struct SpiritWeekDay: Decodable, Sendable, Equatable {
        let theme: String
        let crewRoles: [String]
    }

    let month: String
    let canEdit: Bool
    var entries: [Entry]
    let schedule: [ScheduleDay]
    let queuedPackages: [QueuedPackage]
    var showManagers: [String: ShowManager]
    /// Producers' editing data (absent from older Portals): everyone but advisers, by on-screen name.
    var members: [String]? = nil
    /// Who can be show manager: EPs, the super admin and APs.
    var showManagerPool: [String]? = nil
    /// Anchors & PA counts are exec-only.
    var canViewCastCounts: Bool? = nil
    var spiritWeek: [String: SpiritWeekDay]? = nil

    func content(of date: String) -> String { entries.first { $0.date == date }?.content ?? "" }

    /// The month with one cell replaced (an empty cell is removed, as the Portal does).
    func replacing(_ date: String, content: String) -> CalendarMonth {
        var copy = self
        copy.entries = entries.filter { $0.date != date } + (content.isEmpty ? [] : [Entry(date: date, content: content)])
        return copy
    }
}

/// The Portal's `ScheduleKind`: show day, PA (Monday) day, a class day with neither, or no school.
enum DayKind: String, Decodable, Sendable, Equatable {
    case show = "SHOW"
    case pa = "PA"
    case none = "NONE"
    case holiday = "HOLIDAY"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DayKind(rawValue: raw) ?? .none
    }

    var tag: String {
        switch self {
        case .show: "Show"
        case .pa: "PA"
        case .none: "Class"
        case .holiday: "No school"
        }
    }
}

/// One weekday as the app shows it: what kind of day, who does what, what airs.
struct CalendarDay: Identifiable, Sendable, Equatable {
    let date: String
    let kind: DayKind
    let label: String
    /// "Anchors", "Show Manager", "PA Announcers", crew lists…, in calendar order.
    let roles: [DayContent.Section]
    /// Lines that aren't under a role heading.
    let notes: [String]
    let packages: [CalendarMonth.QueuedPackage]

    var id: String { date }

    func names(for heading: String) -> [String] {
        roles.first { $0.heading.caseInsensitiveCompare(heading) == .orderedSame }?.names ?? []
    }
}

/// `GET api/announcements` (class announcements, newest first).
struct ClassAnnouncement: Decodable, Identifiable, Sendable, Equatable {
    struct Person: Decodable, Sendable, Equatable {
        let id: String
        let name: String
    }

    struct Comment: Decodable, Identifiable, Sendable, Equatable {
        let id: String
        let body: String
        let createdAt: Date
        let author: Person
    }

    let id: String
    let content: String
    let createdAt: Date
    let author: Person
    var unread: Bool
    var likedByMe: Bool
    var likeCount: Int
    let mentions: [Person]
    var comments: [Comment]
}

/// `POST|DELETE api/announcements/<id>/like`.
struct AnnouncementLikeState: Decodable, Sendable {
    let likedByMe: Bool
    let likeCount: Int
}
