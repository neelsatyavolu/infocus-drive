import SwiftUI

/// Screens for `CalendarRoute`.
struct CalendarDestination: View {
    let route: CalendarRoute

    var body: some View {
        switch route {
        case .day(let date):
            DayDetailView(date: date)
        case .theShow:
            TheShowView()
        case .announcements:
            AnnouncementsView()
        case .announcement(let id):
            AnnouncementDetailView(id: id)
        }
    }
}
