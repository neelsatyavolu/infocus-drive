import Foundation

/// `GET api/package-cycle/queue[?candidates=1]` (app/api/package-cycle/queue/route.ts).
struct QueuePayload: Decodable, Sendable, Equatable {
    /// Producers edit the queue; appointed website managers only read it.
    let canEdit: Bool
    let publishingConfigured: Bool?
    let packages: [QueuePackage]
    /// The Portal's today (`YYYY-MM-DD`); past air dates leave the live list.
    let today: String?
    let upcomingShows: [UpcomingShow]
    let candidates: [QueueCandidate]?
}

struct QueuePackage: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let cycleNumber: Int
    let groupTopic: String
    let headline: String?
    /// A producer-uploaded video, not a package-cycle group (cycle 0).
    let custom: Bool
    let queuedForAirAt: Date?
    let queuedForShowDate: String?
    let youtubePublication: YoutubePublication?
    let assignedProducer: QueuePerson?
    let members: [String?]
    let thumbnailUrl: URL?

    /// The topic, or a stand-in the way the web shows it.
    var title: String {
        if !groupTopic.isEmpty { return groupTopic }
        return custom ? "Untitled" : "Untitled group"
    }

    /// The final cut's headline when it says something the topic doesn't.
    var distinctHeadline: String? {
        guard let headline, !headline.isEmpty, headline != groupTopic else { return nil }
        return headline
    }
}

struct YoutubePublication: Decodable, Sendable, Hashable {
    let status: String
    let videoId: String?
    let publishedAt: Date?
    /// Already sanitized by the Portal (never an upload session URL).
    let lastError: String?
}

struct QueuePerson: Decodable, Sendable, Hashable {
    let name: String?
    let email: String?
}

struct UpcomingShow: Decodable, Sendable, Hashable, Identifiable {
    let date: String
    let label: String
    var id: String { date }
}

struct QueueCandidate: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let cycleNumber: Int
    let groupTopic: String
    let custom: Bool?
    let members: [String?]
}

/// `POST api/package-cycle/queue`.
struct QueueUpdate: Encodable, Equatable {
    let rowId: String
    let queued: Bool
    /// nil: keep the current show, or the next empty show when newly queued.
    let showDate: String?
}

/// `GET api/show-roles/publication?date=` (producers): the whole show's YouTube upload.
struct ShowPublicationState: Decodable, Sendable, Equatable {
    struct Publication: Decodable, Sendable, Equatable {
        /// DRAFT, UPLOADING, PROCESSING, FINALIZING, SCHEDULED or FAILED.
        let status: String
        let title: String
        let publishAt: Date
        let seasonNumber: Int?
        let uploadedBytes: Int?
        let totalBytes: Int?
        let watchUrl: URL?
        let lastError: String?
    }

    let showDate: String
    let configured: Bool
    let publication: Publication?
}

/// `GET api/package-cycle/queue/managers` (producers): website managers who can read the queue.
struct PublishingManagers: Decodable, Sendable, Equatable {
    struct Manager: Decodable, Sendable, Identifiable, Hashable {
        let userId: String
        let name: String?
        let email: String?
        var id: String { userId }
    }

    struct Candidate: Decodable, Sendable, Identifiable, Hashable {
        let id: String
        let name: String?
        let email: String?
    }

    let managers: [Manager]
    let candidates: [Candidate]
}

/// `POST api/package-cycle/queue/custom` `{ action: "init" }`: where the video goes.
struct CustomQueueUpload: Decodable, Sendable {
    let mediaId: String
    let versionId: String
    let upload: DriveUploadSession
}
