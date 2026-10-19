import Foundation

/// `GET api/platform/class-board-cycle` (producers): which cycle's packages the Class Board shows.
struct ClassBoardCycleSetting: Decodable, Sendable, Equatable {
    struct Cycle: Decodable, Identifiable, Sendable, Equatable {
        let cycleNumber: Int
        let focus: String

        var id: Int { cycleNumber }

        /// "Cycle 3 · Sports", as the web select reads.
        var label: String {
            let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Cycle \(cycleNumber)" : "Cycle \(cycleNumber) · \(trimmed)"
        }
    }

    /// Nil follows the current cycle (moves on after each Final Cut deadline).
    var cycleNumber: Int?
    let cycles: [Cycle]
    /// Executive producers and up can change it.
    let canEdit: Bool
}

/// `POST api/platform/class-board-cycle` answers with the saved choice.
struct ClassBoardCycleSaved: Decodable, Sendable, Equatable {
    let cycleNumber: Int?
}
