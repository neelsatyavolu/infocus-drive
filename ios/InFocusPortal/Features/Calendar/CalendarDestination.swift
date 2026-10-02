import SwiftUI

/// Screens for `CalendarRoute`. Placeholders show the Portal page until the native screen lands.
struct CalendarDestination: View {
    let route: CalendarRoute

    var body: some View {
        switch route {
        case .day:
            PortalPageScreen(path: "master-calendar", title: "Calendar")
        case .theShow:
            PortalPageScreen(path: "show-roles", title: "The Show")
        case .announcements:
            PortalPageScreen(path: "announcements", title: "Announcements")
        }
    }
}
