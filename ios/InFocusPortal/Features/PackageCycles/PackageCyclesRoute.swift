import Foundation

/// Screens of the Package Cycles feature: the roster and the cycle dates. Owned by the
/// Package Cycles agent.
enum PackageCyclesRoute: Hashable {
    /// Package Cycles (`/package-progress`, `/package-cycles`): the roster for producers and
    /// the cycle dates with Package of the Cycle winners.
    case home
    /// The roster opened on one cycle (`/package-progress?cycle=N`).
    case cycle(number: Int)
    /// One group of a cycle: topic, members, assigned producer, notes.
    case group(rowId: String, cycle: Int)

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["package-progress"]:
            let cycle = query.first { $0.name == "cycle" }?.value.flatMap(Int.init).flatMap { (1...8).contains($0) ? $0 : nil }
            return DeepLinkMatch(tab: .more, route: .packageCycles(cycle.map { .cycle(number: $0) } ?? .home))
        case ["package-cycles"]:
            return DeepLinkMatch(tab: .more, route: .packageCycles(.home))
        default:
            return nil
        }
    }
}
