import Foundation

/// The stages a student works through each cycle (the web sidebar's "The Cycle").
enum StudentStage: String, CaseIterable, Hashable, Identifiable {
    case information
    case brainstorming
    case aRoll = "a-roll"
    case initialCut = "initial-cut"
    case finalCut = "final-cut"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .information: "Information"
        case .brainstorming: "Brainstorming"
        case .aRoll: "A-roll/B-roll"
        case .initialCut: "Initial Cut"
        case .finalCut: "Final Cut"
        }
    }
}

/// Screens of the Work feature (Home, Packages, Groups). Owned by the Work agent.
enum WorkRoute: Hashable {
    /// A package group (producers): `/groups/<rowId>` or `/groups/<rowId>/<stage>`.
    case group(rowId: String, stage: String?)
    /// The signed-in student's own stage this cycle: `/brainstorming`, `/a-roll`, …
    case studentStage(StudentStage)

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path.first {
        case "groups":
            guard path.count >= 2 else { return DeepLinkMatch(tab: .work, route: nil) }
            return DeepLinkMatch(tab: .work, route: .work(.group(rowId: path[1], stage: path.count >= 3 ? path[2] : nil)))
        case let first?:
            guard path.count == 1, let stage = StudentStage(rawValue: first) else { return nil }
            return DeepLinkMatch(tab: .work, route: .work(.studentStage(stage)))
        case nil:
            return nil
        }
    }
}
