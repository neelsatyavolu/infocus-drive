import Foundation

/// Reporting a chat message or a stage feedback comment (App Review Guideline 1.2):
/// `POST api/hub-chat/report`. The Portal checks the reporter can see it, then emails and
/// notifies the InFocus adviser and the executive producers.
struct ContentReport: Encodable, Hashable, Sendable {
    enum Kind: String, Encodable, Sendable { case chat, comment }

    let kind: Kind
    var messageId: String?
    var commentId: String?
    var reason: String?

    static func chat(_ messageId: String) -> ContentReport { ContentReport(kind: .chat, messageId: messageId) }
    static func comment(_ commentId: String) -> ContentReport { ContentReport(kind: .comment, commentId: commentId) }
}

/// What the report sheet shows: whose words, and an excerpt of them.
struct ReportTarget: Identifiable, Hashable, Sendable {
    let report: ContentReport
    let authorName: String
    let excerpt: String

    var id: String { report.messageId ?? report.commentId ?? excerpt }
}

enum ContentReporter {
    static let path = "api/hub-chat/report"

    /// The sample app reports nothing to the Portal; it only says so.
    static func send(_ report: ContentReport, client: PortalClient) async throws {
        if SampleMode.isOn { return }
        try await client.post(path, body: report)
    }

    static var confirmation: String {
        SampleMode.isOn
            ? "Reported (sample app)."
            : "Reported. The InFocus adviser and executive producers will review it."
    }

    /// The reason box's text, trimmed and capped like the Portal (500 characters), or nil.
    static func reason(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
    }
}
