import Foundation

/// `GET|POST api/show-roles/publication` (producers): one show's YouTube upload, plus the draft's
/// defaults until it is sent (src/server/show-publishing.ts `showPublicationState`).
struct ShowUploadState: Decodable, Sendable, Equatable {
    struct Publication: Decodable, Sendable, Equatable {
        /// DRAFT, UPLOADING, PROCESSING, FINALIZING, SCHEDULED or FAILED.
        let status: String
        let title: String
        var description: String? = nil
        let publishAt: Date
        let seasonNumber: Int?
        let uploadedBytes: Int?
        let totalBytes: Int?
        let watchUrl: URL?
        let lastError: String?
    }

    struct Defaults: Decodable, Sendable, Equatable {
        let title: String
        let description: String
        let publishDate: String
        let publishTime: String
        let seasonNumber: Int?
        /// The season playlists on YouTube; nil when YouTube couldn't be read.
        let existingSeasons: [Int]?
    }

    let showDate: String
    let configured: Bool
    let publication: Publication?
    var defaults: Defaults? = nil

    /// Already sent to YouTube: only its status shows (the Portal's "status" step).
    var isSent: Bool { publication.map { $0.status != "DRAFT" } ?? false }
}

/// The Portal's show upload rules (src/lib/show-publication.ts and the publication route's schema).
enum ShowUploadRules {
    static let titleMax = 100
    static let descriptionMax = 5000
    static let thumbnailSeconds = 16.5
    static let thumbnailMaxWidth: CGFloat = 1280
    /// YouTube's custom thumbnail limit.
    static let posterMaxBytes = 2 * 1024 * 1024
    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    /// Still on YouTube's side: check again every 10 seconds.
    static let active: Set<String> = ["UPLOADING", "PROCESSING", "FINALIZING"]

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "UPLOADING": "Uploading"
        case "PROCESSING": "Processing"
        case "FINALIZING": "Finalizing"
        case "SCHEDULED": "Scheduled"
        case "FAILED": "Needs attention"
        case "DRAFT": "Draft"
        default: status
        }
    }

    static func statusDetail(_ status: String) -> String? {
        switch status {
        case "UPLOADING": "Uploading to YouTube…"
        case "PROCESSING": "YouTube is processing the video…"
        case "FINALIZING": "Setting the thumbnail and playlist…"
        default: nil
        }
    }

    /// The playlist line under the season field.
    static func seasonHint(existing: [Int]?, season: String) -> String {
        guard let existing else { return "Couldn't read playlists from YouTube. Check the number." }
        if let number = Int(season.trimmingCharacters(in: .whitespaces)), number > 0, !existing.contains(number) {
            return "New playlist: \"InFocus News | Season \(number)\" will be created."
        }
        return "Adds to the existing playlist."
    }

    /// Whole percent sent to YouTube, when the Portal knows both sizes.
    static func percent(uploaded: Int?, total: Int?) -> Int? {
        guard let uploaded, let total, total > 0 else { return nil }
        return min(100, Int((Double(uploaded) / Double(total) * 100).rounded()))
    }
}

/// The review form before scheduling (the Portal's `Form`).
struct ShowUploadForm: Equatable, Sendable {
    var title: String
    var description: String
    var publishDate: String
    var publishTime: String
    var seasonNumber: String

    init(title: String, description: String, publishDate: String, publishTime: String, seasonNumber: String) {
        self.title = title
        self.description = description
        self.publishDate = publishDate
        self.publishTime = publishTime
        self.seasonNumber = seasonNumber
    }

    init(_ defaults: ShowUploadState.Defaults) {
        self.init(title: defaults.title, description: defaults.description, publishDate: defaults.publishDate,
                  publishTime: defaults.publishTime, seasonNumber: defaults.seasonNumber.map(String.init) ?? "")
    }

    /// The first problem the Portal would refuse, in its words, or nil.
    var problem: String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "Give the show a title." }
        if title.count > ShowUploadRules.titleMax { return "Keep the title to \(ShowUploadRules.titleMax) characters or fewer." }
        if title.contains(where: { "<>".contains($0) }) { return "No < or > in the title." }
        if description.count > ShowUploadRules.descriptionMax {
            return "Keep the description to \(ShowUploadRules.descriptionMax) characters or fewer."
        }
        if description.contains(where: { "<>".contains($0) }) { return "No < or > in the description." }
        if publishDate.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) == nil { return "Pick the day it goes public." }
        if publishTime.wholeMatch(of: #/([01]\d|2[0-3]):[0-5]\d/#) == nil { return "Pick the time it goes public." }
        guard let season, (1...999).contains(season) else { return "Enter a season number." }
        return nil
    }

    var season: Int? { Int(seasonNumber.trimmingCharacters(in: .whitespaces)) }

    /// `POST api/show-roles/publication` with `action: "confirm"`.
    struct Confirm: Encodable, Equatable {
        var action = "confirm"
        let showDate: String
        let title: String
        let description: String
        let publishDate: String
        let publishTime: String
        let seasonNumber: Int
    }

    func confirmBody(showDate: String) -> Confirm? {
        guard problem == nil, let season else { return nil }
        return Confirm(showDate: showDate, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                       description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                       publishDate: publishDate, publishTime: publishTime, seasonNumber: season)
    }

    /// The publish moment, in Pacific time, for the date and time pickers.
    var publishAt: Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ShowUploadRules.timeZone
        let date = publishDate.split(separator: "-").compactMap { Int($0) }
        let time = publishTime.split(separator: ":").compactMap { Int($0) }
        guard date.count == 3, time.count == 2 else { return nil }
        return calendar.date(from: DateComponents(year: date[0], month: date[1], day: date[2], hour: time[0], minute: time[1]))
    }

    mutating func setPublishAt(_ moment: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ShowUploadRules.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
        publishDate = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        publishTime = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
