import Foundation

/// Display rules from the Portal's Grades page, so the app reads the same as the web.
/// Sums and labels only: every score comes from the Portal.
enum GradesPresentation {
    static let maxFinalCutPoints: Double = 50
    static let maxCheckInPointsPerCycle: Double = 20
    static let maxLivestreamPoints: Double = 40
    static let maxPortfolioPoints: Double = 100
    /// Cycles 1–3 are semester 1 (`LAST_S1_CYCLE_NUMBER`).
    static let lastSemesterOneCycle = 3
    /// The web's English month labels (not the device locale's).
    static let monthNames = ["January", "February", "March", "April", "May", "June",
                             "July", "August", "September", "October", "November", "December"]

    struct Totals: Equatable {
        let earned: Double
        let possible: Double

        /// Percent with one decimal, or nil when nothing is gradeable yet.
        var percent: Double? {
            possible > 0 ? (earned / possible * 1000).rounded() / 10 : nil
        }
    }

    /// Final cuts and check-ins that have a score (ungraded ones count for nothing yet).
    static func packageTotals(_ estimated: GradesMe.Estimated?) -> Totals {
        guard let packages = estimated?.packages else { return Totals(earned: 0, possible: 0) }
        let finals = packages.finalCutPoints.compactMap { $0 }
        var earned = finals.reduce(0, +)
        var possible = Double(finals.count) * maxFinalCutPoints
        for (index, points) in packages.checkInPoints.enumerated() {
            guard let points else { continue }
            earned += points
            possible += (at(packages.checkInPossible, index) ?? nil) ?? maxCheckInPointsPerCycle
        }
        return Totals(earned: earned, possible: possible)
    }

    /// Livestream and portfolio, each counted only once it has a score.
    static func otherTotals(_ estimated: GradesMe.Estimated?) -> Totals {
        let livestream = estimated?.packages.livestreamPoints
        let portfolio = estimated?.portfolio.points
        return Totals(earned: (livestream ?? 0) + (portfolio ?? 0),
                      possible: (livestream == nil ? 0 : maxLivestreamPoints) + (portfolio == nil ? 0 : maxPortfolioPoints))
    }

    static func participationTotals(_ estimated: GradesMe.Estimated?) -> Totals {
        Totals(earned: estimated?.participation.earned ?? 0, possible: estimated?.participation.possible ?? 0)
    }

    /// "Cycle 2 · Sports" (the focus up to its first dash or colon), or the month for a cycle without one.
    static func cycleTitle(_ cycle: GradesMe.CycleGrade) -> String {
        let focus = cycle.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !focus.isEmpty {
            let head = focus.split(whereSeparator: { "—-:".contains($0) }).first.map(String.init) ?? focus
            return "Cycle \(cycle.cycleNumber) · \(String(head.trimmingCharacters(in: .whitespaces).prefix(32)))"
        }
        return "Cycle \(cycle.cycleNumber) · \(monthNames[(cycle.cycleNumber - 1) % 12])"
    }

    static func cycleStatus(_ cycle: GradesMe.CycleGrade) -> String {
        cycle.published ? (cycle.revised ? "Published · revised" : "Published") : "In progress"
    }

    /// The gradebook semester's cycles (all of them if the semester label can't be read).
    static func semesterCycles(_ grades: GradesMe) -> [GradesMe.CycleGrade] {
        let ordered = grades.cycles.sorted { $0.cycleNumber < $1.cycleNumber }
        guard let term = semesterTerm(grades.gradebook?.semester.label ?? "") else { return ordered }
        return ordered.filter { ($0.cycleNumber <= lastSemesterOneCycle ? 1 : 2) == term }
    }

    /// "26-27 S1" → 1.
    static func semesterTerm(_ label: String) -> Int? {
        guard let range = label.range(of: #"\bS([12])\b"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return label[range].last == "2" ? 2 : 1
    }

    /// Final-cut and check-in scores of one cycle (they're indexed in cycle order).
    static func scores(for cycle: GradesMe.CycleGrade, in grades: GradesMe) -> (finalCut: Double?, checkIn: Double?, checkInMax: Double) {
        let ordered = grades.cycles.map(\.cycleNumber).sorted()
        guard let index = ordered.firstIndex(of: cycle.cycleNumber), let packages = grades.estimated?.packages else {
            return (nil, nil, maxCheckInPointsPerCycle)
        }
        let max = (at(packages.checkInPossible, index) ?? nil) ?? maxCheckInPointsPerCycle
        return ((at(packages.finalCutPoints, index) ?? nil), (at(packages.checkInPoints, index) ?? nil), max)
    }

    /// The week containing `today` (YYYY-MM-DD), else the last week.
    static func currentWeekIndex(_ weeks: [GradesMe.Week], today: String) -> Int {
        guard !weeks.isEmpty else { return 0 }
        let index = weeks.indices.first { index in
            let next = at(weeks, index + 1)?.weekStart
            return weeks[index].weekStart <= today && (next == nil || next! > today)
        }
        return index ?? weeks.count - 1
    }

    static func dayKind(_ kind: String) -> String {
        switch kind {
        case "PA": "PA"
        case "SHOW": "Show"
        case "HOLIDAY": "Holiday"
        default: "Class"
        }
    }

    /// 40 → "40", 7.5 → "7.5".
    static func points(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// The element at `index`, or nil past either end.
    private static func at<T>(_ array: [T]?, _ index: Int) -> T? {
        guard let array, array.indices.contains(index) else { return nil }
        return array[index]
    }

    static func todayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

