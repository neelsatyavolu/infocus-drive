import Foundation

/// Screens of workspaces, projects and media review. Owned by the Review agent.
enum ReviewRoute: Hashable {
    /// Every workspace this person can see, with its projects (`/workspaces`).
    case workspaces
    /// One project's media, optionally inside a folder (`/projects/<id>[?folderId=]`).
    case project(id: String, folderId: String? = nil)
    /// Reviewing one video or image (`/projects/<id>/review/<mediaId>[?version=]`).
    case media(projectId: String, mediaId: String, versionId: String? = nil)
    /// Guest review links for a project (project owners).
    case shareLinks(projectId: String)

    /// `/workspaces`, `/projects/<id>`, `/projects/<id>/review/<mediaId>`. Guest links (`/g/<token>`)
    /// stay web pages: they're for people without a Portal account.
    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch path.first {
        case "workspaces" where path.count == 1:
            return DeepLinkMatch(tab: .home, route: .review(.workspaces))
        case "projects":
            guard path.count >= 2, !path[1].isEmpty else { return nil }
            let projectId = path[1]
            if path.count == 2 {
                return DeepLinkMatch(tab: .home, route: .review(.project(id: projectId, folderId: value("folderId"))))
            }
            if path.count == 4, path[2] == "review", !path[3].isEmpty {
                return DeepLinkMatch(tab: .home, route: .review(.media(projectId: projectId, mediaId: path[3],
                                                                       versionId: value("version"))))
            }
            return nil
        default:
            return nil
        }
    }
}
