import Foundation

/// Screens of the Messages feature: chats, plus Equipment and Livestreams
/// (which appear under More). Owned by the Messages agent.
enum MessagesRoute: Hashable {
    /// A group or direct chat.
    case conversation(id: String)
    case equipment
    case livestreams
    case livestream(id: String)

    /// `/equipment[/request|/manage]` (and the `equipment.` host) → Equipment; `/livestreams[/<id>]`
    /// → Livestreams; `/messages[/<chatId>]` → Messages (the web has no chat pages; this is for
    /// chat links and future chat notifications).
    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path.first {
        case "equipment":
            return DeepLinkMatch(tab: .more, route: .messages(.equipment))
        case "livestreams":
            let route: MessagesRoute = path.count >= 2 ? .livestream(id: path[1]) : .livestreams
            return DeepLinkMatch(tab: .more, route: .messages(route))
        case "messages":
            return DeepLinkMatch(tab: .messages, route: path.count >= 2 ? .messages(.conversation(id: path[1])) : nil)
        default:
            return nil
        }
    }
}
