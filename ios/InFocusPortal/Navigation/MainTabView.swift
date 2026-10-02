import SwiftUI

/// The signed-in app: one NavigationStack per tab, role-aware titles, badges.
struct MainTabView: View {
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session
    @Environment(BadgeCenter.self) private var badges
    @State private var width: CGFloat = 0

    /// Content stays a readable column on iPad and in landscape (DESIGN.md §10: ~720–900pt).
    static let maxContentWidth: CGFloat = 900

    static func readableInset(for width: CGFloat) -> CGFloat {
        max(0, (width - maxContentWidth) / 2)
    }

    var body: some View {
        TabView(selection: Binding(get: { router.selectedTab }, set: { router.select($0) })) {
            ForEach(AppTab.visible(for: session.user)) { tab in
                NavigationStack(path: router.path(tab)) {
                    root(for: tab)
                        .modifier(SampleTagToolbar(isSample: session.user?.sampleOnly == true))
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
                .contentMargins(.horizontal, Self.readableInset(for: width), for: .scrollContent)
                .tabItem { Label(tab.title(for: session.user), systemImage: tab.systemImage(for: session.user)) }
                .badge(badges.count(tab))
                .tag(tab)
            }
        }
        .tint(Brand.green)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
