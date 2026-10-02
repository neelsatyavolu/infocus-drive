import SwiftUI

/// Screens for `AnnouncementsRoute`.
struct AnnouncementsDestination: View {
    let route: AnnouncementsRoute

    var body: some View {
        switch route {
        case .feed: AnnouncementsView()
        case .announcement(let id): AnnouncementDetailView(id: id)
        case .submitted: PortalFallback(path: "announcements/submitted", title: "Submitted")
        case .pa: PortalFallback(path: "announcements/pa", title: "PA")
        }
    }
}
