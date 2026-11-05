import Foundation

/// What can be caught (`HARVEST_KINDS`, src/lib/thanksgiving-board.ts), in the web board's order.
enum HarvestKind: String, CaseIterable, Codable, Sendable {
    case leaves, pies, wishbones, giantTurkeys, pardons

    /// The web's column labels (`HARVEST_LABELS`).
    var label: String {
        switch self {
        case .leaves: "Leaves"
        case .pies: "Pies"
        case .wishbones: "Wishbones"
        case .giantTurkeys: "Giant turkeys"
        case .pardons: "Pardons"
        }
    }

    var systemImage: String {
        switch self {
        case .leaves: "leaf.fill"
        case .pies: "chart.pie.fill"
        case .wishbones: "sparkles"
        case .giantTurkeys: "bird.fill"
        case .pardons: "medal.fill"
        }
    }
}

/// One person on the board. Ranked rows carry `rank`; disqualified rows don't.
struct HarvestEntry: Decodable, Identifiable, Equatable, Sendable {
    let userId: String
    let name: String
    let leaves: Int
    let pies: Int
    let wishbones: Int
    let giantTurkeys: Int
    let pardons: Int
    let total: Int
    var rank: Int?

    var id: String { userId }

    func count(_ kind: HarvestKind) -> Int {
        switch kind {
        case .leaves: leaves
        case .pies: pies
        case .wishbones: wishbones
        case .giantTurkeys: giantTurkeys
        case .pardons: pardons
        }
    }
}

/// `GET api/thanksgiving` (app/api/thanksgiving/route.ts). The exec review list is left to the web.
struct HarvestBoard: Decodable, Equatable, Sendable {
    struct Winner: Decodable, Equatable, Sendable {
        let userId: String
        let name: String
    }

    struct ContestResult: Decodable, Equatable, Sendable {
        let winners: [Winner]
        let total: Int
        /// Winners with no package group this cycle (an exec adds their days by hand).
        let ungranted: [String]
    }

    struct Contest: Decodable, Equatable, Sendable {
        let closesAt: Date
        let prizeDays: Int
        let result: ContestResult?
    }

    let year: Int
    let rows: [HarvestEntry]
    let disqualified: [HarvestEntry]
    let viewerId: String?
    let contest: Contest?

    var isEmpty: Bool { rows.isEmpty && disqualified.isEmpty }

    /// The viewer was caught by the cheat checks (the web shows "You're disqualified for now").
    var viewerDisqualified: Bool {
        guard let viewerId else { return false }
        return disqualified.contains { $0.userId == viewerId }
    }

    func isViewer(_ entry: HarvestEntry) -> Bool { entry.userId == viewerId }
}

/// The contest banner's words (components/thanksgiving/contest-banner.tsx), for a phone.
struct ContestBannerText: Equatable {
    let headline: String
    let detail: String

    init(contest: HarvestBoard.Contest, viewerId: String?, now: Date = Date(), timeZone: TimeZone = .current) {
        let closes = Self.closesLabel(contest.closesAt, timeZone: timeZone)
        let days = "\(contest.prizeDays) free extension days"
        if now <= contest.closesAt {
            headline = days.uppercased()
            detail = "Whoever is #1 on the leaderboard at \(closes) wins \(contest.prizeDays) extension days for their whole package group. It's the total that counts: leaves, pies, wishbones, giant turkeys and pardons, one point each."
        } else if let result = contest.result, !result.winners.isEmpty {
            let youWon = result.winners.contains { $0.userId == viewerId }
            if youWon {
                headline = "YOU WON \(days.uppercased())"
                let note = result.ungranted.contains(viewerId ?? "")
                    ? "You're not on a package group this cycle, so an exec will add the days by hand."
                    : "The days are already on your group's package. Check Extension requests."
                detail = "You were #1 at \(closes) with \(result.total). \(note)"
            } else {
                headline = "\(Self.joinNames(result.winners.map(\.name)).uppercased()) WON"
                detail = "\(days.prefix(1).uppercased())\(days.dropFirst()) for their package group, #1 at \(closes) with \(result.total). The board keeps counting through November for bragging rights."
            }
        } else {
            headline = "THE CONTEST IS OVER"
            detail = "The board keeps counting through November for bragging rights."
        }
    }

    /// "11:59 PM Thu, Nov 5" in the viewer's time zone (the web's `closesLabel`).
    static func closesLabel(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a EEE, MMM d"
        return formatter.string(from: date)
    }

    static func joinNames(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return "\(names.dropLast().joined(separator: ", ")) and \(last)"
    }
}
