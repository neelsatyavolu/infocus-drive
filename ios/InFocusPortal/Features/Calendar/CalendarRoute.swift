import Foundation

/// Screens of the Calendar feature (Master Calendar, The Show). Announcements
/// live in `AnnouncementsRoute`.
/// Owned by the Calendar agent.
enum CalendarRoute: Hashable {
    /// One school day (`YYYY-MM-DD`): show, anchors, PA.
    case day(date: String)
    /// The Show (`/show-roles`).
    case theShow

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["master-calendar"]:
            let date = query.first { $0.name == "date" }?.value.flatMap { $0.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil ? $0 : nil }
            return DeepLinkMatch(tab: .calendar, route: date.map { .calendar(.day(date: $0)) })
        case ["show-roles"]:
            return DeepLinkMatch(tab: .calendar, route: .calendar(.theShow))
        default:
            return nil
        }
    }
}
