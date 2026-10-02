import Foundation

/// Screens of the Grades feature (grades, extensions). Owned by the Grades agent.
/// Both live under More.
enum GradesRoute: Hashable {
    case grades
    /// Students: my extension requests. Producers: requests to review.
    case extensions
    case extensionRequest(id: String)

    /// `/grades` (also on the grades host: `grades.` → `["grades"]` or `["grades", "grades"]`),
    /// `/extensions[/<id>]`, `/extension-requests[/<id>]`. Other grades-host pages (Grade
    /// Editor, Participation) stay on the web.
    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path.first {
        case "grades" where path == ["grades"] || path == ["grades", "grades"]:
            return DeepLinkMatch(tab: .more, route: .grades(.grades))
        case "extensions", "extension-requests":
            let route: GradesRoute = path.count >= 2 ? .extensionRequest(id: path[1]) : .extensions
            return DeepLinkMatch(tab: .more, route: .grades(route))
        default:
            return nil
        }
    }
}
