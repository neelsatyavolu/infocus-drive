import SwiftUI

/// The signed-in app: one NavigationStack per tab, role-aware titles, badges.
struct MainTabView: View {
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session
    @Environment(BadgeCenter.self) private var badges

    var body: some View {
        TabView(selection: Binding(get: { router.selectedTab }, set: { router.select($0) })) {
            ForEach(AppTab.visible(for: session.user)) { tab in
                NavigationStack(path: router.path(tab)) {
                    root(for: tab)
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
                .tabItem { Label(tab.title(for: session.user), systemImage: tab.systemImage(for: session.user)) }
                .badge(badges.count(tab))
                .tag(tab)
            }
        }
        .tint(Brand.green)
    }

    @ViewBuilder
    private func root(for tab: AppTab) -> some View {
        switch tab {
        case .home: HomeTab()
        case .work: WorkTab()
        case .calendar: CalendarTab()
        case .messages: MessagesTab()
        case .more: MoreTab()
        }
    }
}
