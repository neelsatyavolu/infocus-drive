import Foundation

/// Screens of the Publishing Queue feature. Owned by the Publishing Queue agent.
enum PublishingRoute: Hashable {
    /// The queue: upcoming shows and their packages (`/publishing-queue`).
    case home
    /// One queued package and its YouTube publication (`/publishing-queue/<rowId>`).
    case package(rowId: String)
    /// The whole show's YouTube upload for one air date (producers).
    case show(date: String)
    /// Website managers who can read the queue (producers).
    case managers

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        guard path.first == "publishing-queue" else { return nil }
        switch path.count {
        case 1:
            return DeepLinkMatch(tab: .more, route: .publishing(.home))
        case 2 where !path[1].isEmpty:
            return DeepLinkMatch(tab: .more, route: .publishing(.package(rowId: path[1])))
        default:
            return nil
        }
    }
}
