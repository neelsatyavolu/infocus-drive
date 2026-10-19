import Foundation

/// Class community pages: story Ideas and the Class Board. Owned by the Community agent.
enum CommunityRoute: Hashable {
    /// Story ideas from around the Bay (`/ideas[?date=YYYY-MM-DD]`); nil date is the newest set.
    case ideas(date: String?)
    /// The classroom display (`/class-board`), with its cycle and PIN settings for producers.
    case classBoard

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["ideas"]:
            let date = query.first { $0.name == "date" }?.value
            return DeepLinkMatch(tab: .more, route: .community(.ideas(date: IdeasPage.validDate(date))))
        case ["class-board"]:
            return DeepLinkMatch(tab: .more, route: .community(.classBoard))
        case ["activity"]:
            // The web's old activity feed now redirects to Settings (notification preferences).
            return DeepLinkMatch(tab: .more, route: .more(.settings))
        default:
            return nil
        }
    }
}

/// Where an Ideas set lives on the Portal.
enum IdeasPage {
    /// A run date ("2026-10-05"), or nil for anything else (the newest set).
    static func validDate(_ value: String?) -> String? {
        guard let value, value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// The newest set is `/ideas`; every other set is `/ideas?date=YYYY-MM-DD`.
    static func path(date: String?) -> String {
        validDate(date).map { "ideas?date=\($0)" } ?? "ideas"
    }
}
