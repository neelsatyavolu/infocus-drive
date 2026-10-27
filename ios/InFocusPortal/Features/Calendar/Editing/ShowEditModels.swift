import Foundation

/// One show's automatic edit (`GET api/show-roles/edits?date=`), as the Portal's Editing tab
/// shows it. Types follow `src/lib/show-editor.ts`; statuses and stages stay strings so a newer
/// Portal never breaks decoding. Fictional data only in fixtures.
struct ShowEditState: Decodable, Sendable, Equatable {
    struct Worker: Decodable, Sendable, Equatable {
        struct Health: Decodable, Sendable, Equatable {
            let ok: Bool
            let problems: [String]
        }

        let online: Bool
        let lastSeenAt: Date?
        let busy: Bool
        let version: String?
        let health: Health?
    }

    struct Device: Decodable, Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        let active: Bool
    }

    struct Settings: Decodable, Sendable, Equatable {
        let autoStart: Bool
    }

    struct Pairing: Decodable, Sendable, Equatable {
        let status: String
    }

    struct Recording: Decodable, Sendable, Equatable, Identifiable {
        let path: String
        let name: String
        let size: Double
        let modifiedAt: Date
        /// Unchanged for two minutes, so it has finished copying.
        let stable: Bool
        /// The subfolder of `Shows/` it's in, or nil when it's loose in `Shows/`.
        let folder: String?

        var id: String { path }
    }

    struct QueuedPackage: Decodable, Sendable, Equatable {
        let title: String
        let ready: Bool
    }

    struct Preview: Decodable, Sendable, Equatable {
        let videoUrl: URL
        let posterUrl: URL?
    }

    struct Published: Decodable, Sendable, Equatable {
        let status: String
        let publishAt: Date
        let youtubeUrl: URL?
    }

    struct Approve: Decodable, Sendable, Equatable {
        let title: String
        /// Sent back as is with Approve & schedule (the Portal checks it's the time the producer confirmed).
        let publishAt: String
        let problem: String?
    }

    struct AutoStart: Decodable, Sendable, Equatable {
        let files: [ShowEditSource]
        let ready: Bool
        let readyAt: Date?
        let error: String?
    }

    let worker: Worker
    let devices: [Device]
    let waitingFor: String?
    let settings: Settings
    let pairings: [Pairing]
    let recordings: [Recording]
    let recordingsError: String?
    let packages: [QueuedPackage]
    /// Announcements in the show's script (A2); nil when the show has no script yet.
    let announcements: Int?
    let job: ShowEditJob?
    /// The show's YouTube publication status (DRAFT until scheduled), or nil when nothing was uploaded.
    let publicationStatus: String?
    let preview: Preview?
    let published: Published?
    let approve: Approve?
    let autoStart: AutoStart?

    /// Sent to YouTube (scheduled, sending or live): the edit is read-only from here.
    var sentToYouTube: Bool { publicationStatus != nil && publicationStatus != "DRAFT" }

    /// No edit yet, or the last one failed or was cancelled.
    var canStart: Bool { !sentToYouTube && (job.map { ["FAILED", "CANCELLED"].contains($0.status) } ?? true) }

    /// An edit or a machine sign-in is in flight: the screen checks every 10 seconds instead of every minute.
    var isActive: Bool { job?.isActive == true || pairings.contains { ["waiting", "sent"].contains($0.status) } }
}

struct ShowEditJob: Decodable, Sendable, Equatable, Identifiable {
    struct Decision: Decodable, Sendable, Equatable {
        let kind: String
        let detail: String
        let flagged: Bool
    }

    struct Message: Decodable, Sendable, Equatable {
        let from: String
        let text: String
        let version: Int?
    }

    let id: String
    let status: String
    let stage: String?
    let message: String?
    let note: String?
    /// The publish time picked with the instructions; nil means the usual 8:30 AM on show day.
    let publishAt: Date?
    let decisions: [Decision]
    let checks: ShowEditChecks?
    let costUsd: Double?
    let error: String?
    let cancelRequested: Bool
    let pendingFix: String?
    let conversation: [Message]
    let version: Int
    let finishedAt: Date?

    var isActive: Bool { status == "QUEUED" || status == "RUNNING" }
}

/// The parts of a job's free-form `checks` the app shows: chapters and failed checks.
/// Anything malformed is skipped, like `chaptersOf` on the Portal.
struct ShowEditChecks: Decodable, Sendable, Equatable {
    let chapters: [ShowChapter]
    let failures: [String]

    init(chapters: [ShowChapter] = [], failures: [String] = []) {
        self.chapters = chapters
        self.failures = failures
    }

    private enum Keys: String, CodingKey { case chapters, failures }

    private struct RawChapter: Decodable {
        let title: String?
        let start: Double?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try? container.decode(String.self, forKey: .title)
            start = try? container.decode(Double.self, forKey: .start)
        }
        private enum CodingKeys: String, CodingKey { case title, start }
    }

    private struct RawFailure: Decodable {
        let text: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = (try? container.decode(String.self, forKey: .detail)) ?? (try? container.decode(String.self, forKey: .rule))
        }
        private enum CodingKeys: String, CodingKey { case detail, rule }
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let raw = ((try? container.decode([Lenient<RawChapter>].self, forKey: .chapters)) ?? []).compactMap(\.value)
        chapters = ShowChapter.cleaned(raw.compactMap { entry in
            guard let title = entry.title, let start = entry.start else { return nil }
            return ShowChapter(title: title, start: start)
        })
        failures = ((try? container.decode([Lenient<RawFailure>].self, forKey: .failures)) ?? []).compactMap { $0.value?.text }
    }
}

/// A chapter of the edited show: its title and seconds into the render.
struct ShowChapter: Sendable, Equatable, Hashable {
    let title: String
    let start: Double

    /// In time order, the first at 0, at most 40, like `chaptersOf`.
    static func cleaned(_ chapters: [ShowChapter]) -> [ShowChapter] {
        let kept = chapters
            .compactMap { chapter -> ShowChapter? in
                let title = String(chapter.title.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(100))
                guard !title.isEmpty, chapter.start.isFinite, chapter.start >= 0 else { return nil }
                return ShowChapter(title: title, start: chapter.start)
            }
            .sorted { $0.start < $1.start }
            .prefix(40)
        guard let first = kept.first else { return [] }
        return [ShowChapter(title: first.title, start: 0)] + kept.dropFirst()
    }

    /// `75.4` → "1:15"; an hour or more → "1:02:03".
    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// One recording picked for an edit, with what it is.
struct ShowEditSource: Codable, Sendable, Equatable, Hashable {
    enum Role: String, Codable, Sendable, CaseIterable {
        case auto, program, M, L, R, ignore

        var label: String {
            switch self {
            case .auto: "Auto (the editor works it out)"
            case .program: "Program"
            case .M: "Camera M (two-shot)"
            case .L: "Camera L"
            case .R: "Camera R"
            case .ignore: "Ignore"
            }
        }
    }

    let path: String
    let role: Role

    init(path: String, role: Role) {
        self.path = path
        self.role = role
    }

    /// An unknown role from a newer Portal reads as Auto.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        role = (try? container.decode(Role.self, forKey: .role)) ?? .auto
    }

    private enum CodingKeys: String, CodingKey { case path, role }

    var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// What the screen sends (`POST api/show-roles/edits`), matching the Portal's action schema.
enum ShowEditAction: Encodable, Sendable, Equatable {
    struct PublishSlot: Encodable, Sendable, Equatable {
        let date: String
        let time: String
    }

    case start(date: String, sources: [ShowEditSource], note: String?, publish: PublishSlot?)
    case cancel(id: String)
    case redo(id: String, note: String?)
    case fix(id: String, text: String, remember: Bool)
    case approve(id: String, publishAt: String)

    var name: String {
        switch self {
        case .start: "start"
        case .cancel: "cancel"
        case .redo: "redo"
        case .fix: "fix"
        case .approve: "approve"
        }
    }

    private enum Keys: String, CodingKey { case action, date, sources, note, publish, id, text, remember, publishAt }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(name, forKey: .action)
        switch self {
        case .start(let date, let sources, let note, let publish):
            try container.encode(date, forKey: .date)
            try container.encode(sources, forKey: .sources)
            try container.encodeIfPresent(note, forKey: .note)
            try container.encodeIfPresent(publish, forKey: .publish)
        case .cancel(let id):
            try container.encode(id, forKey: .id)
        case .redo(let id, let note):
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(note, forKey: .note)
        case .fix(let id, let text, let remember):
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
            try container.encode(remember, forKey: .remember)
        case .approve(let id, let publishAt):
            try container.encode(id, forKey: .id)
            try container.encode(publishAt, forKey: .publishAt)
        }
    }
}
