import Foundation

/// Words and tone for a YouTube upload's status: a queued package's
/// (`YoutubePublication`) or the whole show's (`ShowPublication`).
struct PublicationStatus: Equatable {
    let label: String
    let detail: String
    let tone: StatusTag.Tone

    /// A package: PUBLISHED, UPLOADING, PROCESSING, FAILED, or nothing yet.
    static func package(_ publication: YoutubePublication?) -> PublicationStatus {
        switch publication?.status {
        case "PUBLISHED":
            PublicationStatus(label: "Published", detail: "Published on YouTube", tone: .success)
        case "UPLOADING":
            PublicationStatus(label: "Uploading", detail: "Uploading to YouTube…", tone: .warning)
        case "PROCESSING":
            PublicationStatus(label: "Processing", detail: "YouTube is processing this video.", tone: .warning)
        case "FAILED":
            PublicationStatus(label: "Failed", detail: "Publishing failed. Contact a producer for help.", tone: .danger)
        default:
            PublicationStatus(label: "Pending", detail: "Not published to YouTube yet.", tone: .neutral)
        }
    }

    /// The whole show's upload (The Show → Upload show).
    static func show(_ publication: ShowPublicationState.Publication?) -> PublicationStatus {
        switch publication?.status {
        case "UPLOADING":
            PublicationStatus(label: "Uploading", detail: "Sending the show to YouTube.", tone: .warning)
        case "PROCESSING":
            PublicationStatus(label: "Processing", detail: "YouTube is processing the show.", tone: .warning)
        case "FINALIZING":
            PublicationStatus(label: "Finishing", detail: "Setting the thumbnail and season playlist.", tone: .warning)
        case "SCHEDULED":
            PublicationStatus(label: "Scheduled", detail: "Scheduled on YouTube.", tone: .success)
        case "FAILED":
            PublicationStatus(label: "Failed", detail: "The show upload stopped. A producer needs to fix it.", tone: .danger)
        case "DRAFT":
            PublicationStatus(label: "Draft", detail: "Uploaded to Drive, not sent to YouTube yet.", tone: .neutral)
        default:
            PublicationStatus(label: "Not uploaded", detail: "The show hasn't been uploaded yet.", tone: .neutral)
        }
    }

    /// "42%" of an upload in progress, when both sizes are known.
    static func percent(uploaded: Int?, total: Int?) -> Int? {
        guard let uploaded, let total, total > 0 else { return nil }
        return min(100, max(0, Int((Double(uploaded) / Double(total) * 100).rounded())))
    }
}
