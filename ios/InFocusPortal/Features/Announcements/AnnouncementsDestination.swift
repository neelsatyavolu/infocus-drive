import SwiftUI

/// Screens for `AnnouncementsRoute`.
struct AnnouncementsDestination: View {
    let route: AnnouncementsRoute

    var body: some View {
        switch route {
        case .feed: AnnouncementsView()
        case .announcement(let id): SlackPostDetailView(id: id)
        case .submitted: SubmittedView()
        case .pa: PAEditorView()
        }
    }
}
