import Foundation

/// Screens of the Package Cycles feature. Owned by the Package Cycles agent.
enum PackageCyclesRoute: Hashable {
    /// The Package Cycles home (`/package-progress`).
    case home

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["package-progress"], ["package-cycles"]:
            return DeepLinkMatch(tab: .more, route: .packageCycles(.home))
        default:
            return nil
        }
    }
}
