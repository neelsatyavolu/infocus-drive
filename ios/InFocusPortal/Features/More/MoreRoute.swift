import SwiftUI

/// Screens of the More tab that the app shell owns.
enum MoreRoute: Hashable {
    case settings
    case portalPages

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        path == ["settings"] ? DeepLinkMatch(tab: .more, route: .more(.settings)) : nil
    }
}

struct MoreDestination: View {
    let route: MoreRoute

    var body: some View {
        switch route {
        case .settings: SettingsScreen()
        case .portalPages: PortalPagesScreen()
        }
    }
}
