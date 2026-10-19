import Foundation

/// Screens of the Calendar feature (Master Calendar, The Show, the teleprompter). Announcements
/// live in `AnnouncementsRoute`.
/// Owned by the Calendar agent.
enum CalendarRoute: Hashable {
    /// One school day (`YYYY-MM-DD`): show, anchors, PA.
    case day(date: String)
    /// The Show (`/show-roles`).
    case theShow
    /// Upload a whole show to YouTube (The Show's Upload show, producers).
    case showUpload(date: String)
    /// The teleprompter (`/teleprompter[?showDate=&doc=]`, or the `teleprompter.` host).
    case teleprompter(showDate: String?, docId: String?)

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["master-calendar"]:
            return DeepLinkMatch(tab: .calendar, route: dateKey("date", in: query).map { .calendar(.day(date: $0)) })
        case ["show-roles"]:
            return DeepLinkMatch(tab: .calendar, route: .calendar(.theShow))
        case ["teleprompter"], ["teleprompter", "teleprompter"]:
            let doc = query.first { $0.name == "doc" }?.value?.trimmingCharacters(in: .whitespaces)
            return DeepLinkMatch(tab: .calendar, route: .calendar(.teleprompter(showDate: dateKey("showDate", in: query),
                                                                                docId: doc?.isEmpty == false ? doc : nil)))
        default:
            return nil
        }
    }

    /// A `YYYY-MM-DD` query value, or nil.
    private static func dateKey(_ name: String, in query: [URLQueryItem]) -> String? {
        query.first { $0.name == name }?.value.flatMap { $0.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil ? $0 : nil }
    }

    /// The teleprompter link The Show hands out (`/teleprompter?showDate=…&doc=…`) as a route.
    static func teleprompter(href: String) -> CalendarRoute {
        let items = URLComponents(string: href)?.queryItems ?? []
        if case .calendar(let route)? = deepLink(["teleprompter"], items)?.route { return route }
        return .teleprompter(showDate: nil, docId: nil)
    }
}
