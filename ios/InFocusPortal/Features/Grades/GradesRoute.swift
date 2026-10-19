import Foundation

/// Screens of the Grades feature (grades, extensions, and the producers' Members and
/// Participation). Owned by the Grades agent. All live under More.
enum GradesRoute: Hashable {
    case grades
    /// Students: my extension requests. Producers: requests to review.
    case extensions
    case extensionRequest(id: String)
    /// Producers: class members with General and per-cycle notes (`/members`).
    case members
    /// Producers: score each class day; approve docked scores (`/participation`).
    case participation

    /// `/grades` (also on the grades host: `grades.` → `["grades"]` or `["grades", "grades"]`),
    /// `/extensions[/<id>]`, `/extension-requests[/<id>]`, `/members`, `/participation` (also on
    /// the grades host). The Grade Editor parses its own paths.
    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path.first {
        case "grades" where path == ["grades"] || path == ["grades", "grades"]:
            return DeepLinkMatch(tab: .more, route: .grades(.grades))
        case "members" where path == ["members"]:
            return DeepLinkMatch(tab: .more, route: .grades(.members))
        case "participation" where path == ["participation"]:
            return DeepLinkMatch(tab: .more, route: .grades(.participation))
        case "grades" where path == ["grades", "participation"]:
            return DeepLinkMatch(tab: .more, route: .grades(.participation))
        case "extensions", "extension-requests":
            let route: GradesRoute = path.count >= 2 ? .extensionRequest(id: path[1]) : .extensions
            return DeepLinkMatch(tab: .more, route: .grades(route))
        default:
            return nil
        }
    }
}
