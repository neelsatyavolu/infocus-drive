import Foundation

/// Screens of the Calendar feature (Master Calendar, The Show, announcements).
/// Owned by the Calendar agent.
enum CalendarRoute: Hashable {
    /// One school day (`YYYY-MM-DD`): show, anchors, PA.
    case day(date: String)
    /// The Show (`/show-roles`).
    case theShow
    /// The class announcements feed (`/announcements`).
    case announcements

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["master-calendar"]:
            let date = query.first { $0.name == "date" }?.value
            return DeepLinkMatch(tab: .calendar, route: date.map { .calendar(.day(date: $0)) })
        case ["show-roles"]:
            return DeepLinkMatch(tab: .calendar, route: .calendar(.theShow))
        case ["announcements"]:
            return DeepLinkMatch(tab: .calendar, route: .calendar(.announcements))
        default:
            return nil
        }
    }
}
