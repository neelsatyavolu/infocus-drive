import Foundation

/// Meetings (producers): the list in More, and the full-screen call.
enum MeetingsRoute: Hashable {
    case home
    /// The call for one meeting. `Router` presents it full screen instead of pushing it.
    case call(id: String)

    /// `/meetings` → the list (More). `/meet/<id>` (meeting pushes) → the call.
    /// `/meetings/<id>` (a meeting's notes page) falls through to the web view.
    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path.count {
        case 1 where path[0] == "meetings":
            return DeepLinkMatch(tab: .more, route: .meetings(.home))
        case 2 where path[0] == "meet" && isMeetingId(path[1]):
            return DeepLinkMatch(tab: nil, route: .meetings(.call(id: path[1])))
        default:
            return nil
        }
    }

    static func isMeetingId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
