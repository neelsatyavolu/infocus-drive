import SwiftUI

/// The screen for a pushed `Route`. Each feature's `…Destination` (in its own
/// folder) decides its cases, so features never edit this file.
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .work(let route): WorkDestination(route: route)
        case .calendar(let route): CalendarDestination(route: route)
        case .grades(let route): GradesDestination(route: route)
        case .messages(let route): MessagesDestination(route: route)
        case .more(let route): MoreDestination(route: route)
        case .portal(let page): PortalPageScreen(page: page)
        }
    }
}
