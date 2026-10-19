import SwiftUI

/// Screens for `ReviewRoute`.
struct ReviewDestination: View {
    let route: ReviewRoute

    var body: some View {
        switch route {
        case .workspaces: WorkspacesScreen()
        case .project(let id, let folderId): ProjectScreen(projectId: id, folderId: folderId)
        case .media(let projectId, let mediaId, let versionId): ReviewScreen(projectId: projectId, mediaId: mediaId, versionId: versionId)
        case .shareLinks(let projectId): ShareLinksScreen(projectId: projectId)
        }
    }
}
