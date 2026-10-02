import Foundation

/// Screens of the Publishing Queue feature. Owned by the Publishing Queue agent.
enum PublishingRoute: Hashable {
    /// The Publishing Queue home (`/publishing-queue`).
    case home

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["publishing-queue"]:
            return DeepLinkMatch(tab: .more, route: .publishing(.home))
        default:
            return nil
        }
    }
}
