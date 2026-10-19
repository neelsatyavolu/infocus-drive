import Foundation

/// `GET api/meetings/<id>` → `{ meeting }` (Portal `MeetingDetail`): the notes page.
struct MeetingDetailResponse: Decodable, Sendable {
    let meeting: MeetingDetail
}

struct MeetingPerson: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct MeetingDetail: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let startsAt: Date
    let durationMinutes: Int
    /// SCHEDULED, LIVE, ENDED, CANCELED.
    let status: String
    /// OPEN, INVITE_ONLY or EXECS_ONLY.
    let access: String
    let isHost: Bool
    let canEdit: Bool
    /// NONE, RECORDING, PROCESSING, READY, FAILED.
    let notesStatus: String
    let participantCount: Int
    let notesSummary: String?
    let notesError: String?
    let invitees: [MeetingPerson]
    let hasTranscript: Bool
    let startedAt: Date?
    let endedAt: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        startsAt = try c.decode(Date.self, forKey: .startsAt)
        durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 60
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "ENDED"
        access = try c.decodeIfPresent(String.self, forKey: .access) ?? "OPEN"
        isHost = try c.decodeIfPresent(Bool.self, forKey: .isHost) ?? false
        canEdit = try c.decodeIfPresent(Bool.self, forKey: .canEdit) ?? false
        notesStatus = try c.decodeIfPresent(String.self, forKey: .notesStatus) ?? "NONE"
        participantCount = try c.decodeIfPresent(Int.self, forKey: .participantCount) ?? 0
        notesSummary = try c.decodeIfPresent(String.self, forKey: .notesSummary)
        notesError = try c.decodeIfPresent(String.self, forKey: .notesError)
        invitees = try c.decodeIfPresent([MeetingPerson].self, forKey: .invitees) ?? []
        hasTranscript = try c.decodeIfPresent(Bool.self, forKey: .hasTranscript) ?? false
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startsAt, durationMinutes, status, access, isHost, canEdit, notesStatus, participantCount
        case notesSummary, notesError, invitees, hasTranscript, startedAt, endedAt
    }

    var isLive: Bool { status == "LIVE" }
    /// Hosts edit who's invited while the meeting isn't over.
    var canEditInvitees: Bool { isHost && canEdit }

    /// Why there's no summary (`NOTES_COPY` on the web).
    var notesMessage: String {
        switch notesStatus {
        case "RECORDING": "The Drive is recording this meeting. Notes appear after it ends."
        case "PROCESSING": "The Drive is transcribing and summarizing. Check back in a few minutes."
        case "FAILED": "Notes couldn't be made for this meeting."
        case "NONE": "No notes were taken for this meeting."
        default: "No summary yet."
        }
    }

    var accessLabel: String? {
        switch access {
        case "INVITE_ONLY": "Invite only"
        case "EXECS_ONLY": "Execs only"
        default: nil
        }
    }

    /// "1 h 30 min", "45 min".
    var durationLabel: String {
        let hours = durationMinutes / 60, minutes = durationMinutes % 60
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }
}

/// `GET api/meetings/<id>/transcript`.
struct MeetingTranscript: Decodable, Sendable {
    let markdown: String
}

/// `GET api/meetings/people`: every producer, for the invite list.
struct MeetingPeople: Decodable, Sendable {
    let people: [MeetingPerson]
}

/// The Scribe's summary markdown as the web renders it (`splitMarkdownSections` +
/// `parseAssistantReply`): "#" headings, paragraphs, "-", "*" or "1." bullets, **bold**.
enum NotesMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        case list([String])
    }

    struct Section: Equatable {
        let heading: String?
        let blocks: [Block]
    }

    static func parse(_ markdown: String) -> [Section] {
        var sections: [(heading: String?, lines: [String])] = [(nil, [])]
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let heading = heading(trimmed) {
                sections.append((heading, []))
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        return sections.compactMap { section in
            let blocks = blocks(section.lines)
            return section.heading == nil && blocks.isEmpty ? nil : Section(heading: section.heading, blocks: blocks)
        }
    }

    /// "## Decisions" → "Decisions" (one to six #, then whitespace and text).
    static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first?.isWhitespace == true else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// "- item", "* item" or "2. item" → "item".
    static func bullet(_ line: String) -> String? {
        var rest = Substring(line)
        if rest.first == "-" || rest.first == "*" {
            rest = rest.dropFirst()
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }.count
            guard digits > 0, rest.dropFirst(digits).first == "." else { return nil }
            rest = rest.dropFirst(digits + 1)
        }
        guard rest.first?.isWhitespace == true else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func blocks(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [String] = []
        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushList() {
            if !list.isEmpty { blocks.append(.list(list)) }
            list = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                flushList()
            } else if let item = bullet(trimmed) {
                flushParagraph()
                list.append(item)
            } else {
                flushList()
                paragraph.append(trimmed)
            }
        }
        flushParagraph()
        flushList()
        return blocks
    }

    /// Inline **bold** only; every other character stays literal text (no links, no HTML).
    static func inline(_ text: String) -> AttributedString {
        var result = AttributedString()
        let parts = text.components(separatedBy: "**")
        for (index, part) in parts.enumerated() where !part.isEmpty {
            var piece = AttributedString(part)
            // Odd pieces sat between a pair of ** (a lone trailing ** stays plain).
            if index % 2 == 1 && index < parts.count - 1 { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
        }
        return result
    }
}
