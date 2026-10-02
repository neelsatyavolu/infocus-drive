import Foundation

/// Screens of the Messages feature: chats, plus Equipment and Livestreams
/// (which appear under More). Owned by the Messages agent.
enum MessagesRoute: Hashable {
    /// A group or direct chat.
    case conversation(id: String)
    case equipment
    case livestreams
    case livestream(id: String)

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path.first {
        case "equipment":
            return DeepLinkMatch(tab: .more, route: .messages(.equipment))
        case "livestreams":
            let route: MessagesRoute = path.count >= 2 ? .livestream(id: path[1]) : .livestreams
            return DeepLinkMatch(tab: .more, route: .messages(route))
        default:
            return nil
        }
    }
}
