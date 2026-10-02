import Foundation

// MARK: Slack feed (`GET api/announcements/slack`)

/// The #announcements channel, as `/announcements` shows it.
struct SlackFeed: Decodable, Sendable, Equatable {
    let configured: Bool
    let items: [SlackPost]
    let error: String?
}

/// One Slack post. `parts` is the text split into plain runs and safe links.
struct SlackPost: Decodable, Identifiable, Sendable, Equatable {
    struct Attachment: Decodable, Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let prettyType: String?
    }

    enum Part: Decodable, Sendable, Equatable {
        case text(String)
        case link(href: String, label: String)

        private enum Keys: String, CodingKey { case type, value, href, label }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if try container.decode(String.self, forKey: .type) == "link" {
                self = .link(href: try container.decode(String.self, forKey: .href),
                             label: try container.decode(String.self, forKey: .label))
            } else {
                self = .text(try container.decodeIfPresent(String.self, forKey: .value) ?? "")
            }
        }
    }

    let id: String
    /// Slack's message timestamp ("1727900000.123456"): later posts sort higher.
    let ts: String
    let authorName: String
    let authorImageUrl: String?
    let text: String
    let parts: [Part]
    let attachments: [Attachment]
    let postedAt: String
    let dateLabel: String
    let timeLabel: String
    let permalink: String

    /// What to show: the parsed parts, or the raw text when Slack sent none.
    var bodyParts: [Part] { parts.isEmpty && !text.isEmpty ? [.text(text)] : parts }

    var sortKey: Double { Double(ts) ?? 0 }
}

// MARK: Submitted (`GET api/announcements/submitted/grouped`)

/// Submitted announcements, grouped by the Portal exactly as `/announcements/submitted` does.
struct SubmittedBoard: Decodable, Sendable, Equatable {
    struct Bucket: Decodable, Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let defaultOpen: Bool
        let copyText: String
        var entries: [SubmittedEntry]
    }

    let canDelete: Bool
    let canInvite: Bool
    let collegeVisitsUrl: String?
    let retrievedAt: String?
    var total: Int
    let airToday: Int
    let airTomorrow: Int
    var buckets: [Bucket]
}

struct SubmittedEntry: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let announcement: String
    let copyText: String
    let destination: String
    let submitterRole: String
    let name: String
    let email: String
    let isPermanent: Bool
    let startDate: String
    let endDate: String
    let submittedAt: String
    let mediaLink: String
    let moreInfo: String
}

/// `POST api/announcements/submitted/invite` → a share link (and how many emails went out).
struct SubmittedInvite: Decodable, Sendable, Equatable {
    let shareUrl: String
    let emailed: Int?
}

enum InviteDuration: String, CaseIterable, Identifiable, Sendable {
    case thirtyDays = "30d"
    case oneYear = "1y"

    var id: String { rawValue }
    var label: String { self == .thirtyDays ? "30 days" : "1 year" }
}

// MARK: PA (`/api/announcements/pa`)

/// The next PA: date, who's on the mic, and the shared script (with its version for safe saves).
struct PAPage: Decodable, Sendable, Equatable {
    struct Script: Decodable, Sendable, Equatable {
        let content: String
        let version: Int
    }

    struct Autofill: Decodable, Sendable, Equatable {
        let status: String
        let message: String?
    }

    let date: String?
    let dateLabel: String
    let timeLabel: String?
    let announcers: [String]
    let canEdit: Bool
    let autofill: Autofill?
    let script: Script?
}
