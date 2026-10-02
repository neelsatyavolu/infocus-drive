import Foundation

/// Screens of the Announcements feature: the #announcements feed, submitted announcements
/// (producers) and the Monday PA script. Owned by the Announcements agent.
enum AnnouncementsRoute: Hashable {
    /// The #announcements feed from Slack (`/announcements`).
    case feed
    /// One Slack post in full (feed item id).
    case announcement(id: String)
    /// Announcements people submitted for the show (`/announcements/submitted`, producers).
    case submitted
    /// The PA script (`/announcements/pa`; producers and the assigned announcers edit it).
    case pa

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["announcements"]:
            return DeepLinkMatch(tab: .calendar, route: .announcements(.feed))
        case ["announcements", "submitted"]:
            return DeepLinkMatch(tab: .more, route: .announcements(.submitted))
        case ["announcements", "pa"]:
            return DeepLinkMatch(tab: .more, route: .announcements(.pa))
        default:
            return nil
        }
    }
}
