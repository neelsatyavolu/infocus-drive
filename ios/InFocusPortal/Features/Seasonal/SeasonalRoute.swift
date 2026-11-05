import SwiftUI

/// Seasonal screens: the Thanksgiving leaderboard (`/thanksgiving`).
enum SeasonalRoute: Hashable {
    case leaderboard

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        path == ["thanksgiving"] ? DeepLinkMatch(tab: .more, route: .seasonal(.leaderboard)) : nil
    }
}

struct SeasonalDestination: View {
    let route: SeasonalRoute

    var body: some View {
        switch route {
        case .leaderboard: LeaderboardScreen()
        }
    }
}
