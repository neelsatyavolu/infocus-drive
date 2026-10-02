import Foundation

/// Rules the Grade Editor shares with the web (`grade-editor-client.tsx`,
/// `src/lib/grade-score.ts`). Pure, so tests can pin them. Never grading math:
/// totals and percentages always come from the Portal.
enum GradeEditorLogic {
    static let maxFinalCut = 50
    static let maxCheckIn = 5
    static let maxFeedback = 2000
    static let maxTotalNotes = 5000
    static let maxParticipationNotes = 600

    /// A typed Final Cut score, like `parseGradeScore`: blank or "-" is ungraded,
    /// "\" is exempt, a number is rounded and capped at 50. Nil rejects the text.
    enum FinalCutInput: Equatable {
        case points(Int)
        case state(ScoreState)
    }

    static func parseFinalCut(_ text: String) -> FinalCutInput? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == "-" || value == "—" { return .state(.ungraded) }
        if value == "\\" { return .state(.exempt) }
        guard value.wholeMatch(of: /\d+(\.\d*)?/) != nil, let number = Double(value) else { return nil }
        return .points(min(maxFinalCut, Int(number.rounded())))
    }

    /// What the web shows in the Final Cut field for a row.
    static func finalCutText(_ row: CycleGradeRow) -> String {
        if row.finalCutState == .exempt { return "\\" }
        guard let points = row.effortPoints else { return "" }
        return points.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// The web's `isRowFilledIn`: only a row with a Final Cut score can be published.
    static func canPublish(_ row: CycleGradeRow) -> Bool { row.effortPoints != nil }

    /// "42", "42.5", or "—".
    static func points(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    // MARK: Cycle list

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", toGrade = "To grade", unpublished = "Unpublished", published = "Published"
        var id: String { rawValue }

        func includes(_ row: CycleGradeRow) -> Bool {
            switch self {
            case .all: true
            case .toGrade: row.effortPoints == nil && row.finalCutState != .exempt
            case .unpublished: canPublish(row) && !row.published
            case .published: row.published
            }
        }
    }

    enum Status: Equatable {
        case revised, published, unpublished
        var label: String {
            switch self {
            case .revised: "Revised"
            case .published: "Published"
            case .unpublished: "Unpublished"
            }
        }
    }

    /// The web's status pill: Revised wins, then Published.
    static func status(_ row: CycleGradeRow) -> Status {
        row.revised ? .revised : row.published ? .published : .unpublished
    }

    static func rows(_ rows: [CycleGradeRow], filter: Filter, search: String) -> [CycleGradeRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { row in
            filter.includes(row) && (query.isEmpty
                || row.displayName.lowercased().contains(query)
                || (row.email?.lowercased().contains(query) ?? false))
        }
    }

    /// Rows "Publish all" would publish: graded and not yet published.
    static func publishable(_ rows: [CycleGradeRow]) -> [CycleGradeRow] {
        rows.filter { canPublish($0) && !$0.published }
    }

    // MARK: Check-ins

    /// Choices for one check-in cell, as on the web: Ungraded, Exempt, Automatic, 0–5.
    enum CheckInChoice: Hashable, Identifiable {
        case automatic, state(ScoreState), points(Int)

        var id: String {
            switch self {
            case .automatic: "auto"
            case .state(let state): state.rawValue
            case .points(let points): "\(points)"
            }
        }

        static let all: [CheckInChoice] = [.state(.ungraded), .state(.exempt), .automatic] + (0...maxCheckIn).map { .points($0) }

        /// The `points` the Portal expects: nil clears the override (automatic).
        var body: CheckInPoints? {
            switch self {
            case .automatic: nil
            case .state(let state): .state(state)
            case .points(let points): .points(points)
            }
        }
    }

    static func choice(override: CheckInValue?) -> CheckInChoice {
        switch override {
        case nil: .automatic
        case .points(let points): .points(points)
        case .state(let state): .state(state)
        }
    }

    // MARK: Participation

    static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    private static var pacificCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        calendar.firstWeekday = 2
        return calendar
    }

    /// `YYYY-MM-DD` in Pacific time.
    static func dateKey(_ date: Date) -> String {
        let parts = pacificCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return pacificCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// The Monday that starts the week holding `date` (Pacific).
    static func weekStart(of date: Date) -> String {
        let calendar = pacificCalendar
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return dateKey(start)
    }

    static func shiftWeek(_ key: String, by weeks: Int) -> String {
        guard let date = date(fromKey: key),
              let shifted = pacificCalendar.date(byAdding: .day, value: weeks * 7, to: date) else { return key }
        return dateKey(shifted)
    }

    /// "Tue, Oct 6" for a date key.
    static func dayLabel(_ key: String) -> String {
        guard let date = date(fromKey: key) else { return key }
        var style = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = pacific
        return date.formatted(style)
    }

    /// Cells the producer changed, ready for `POST api/participation`. Points are capped at the day's max.
    static func changedEntries(edits: [String: ParticipationEdit], week: ParticipationWeek, date: String) -> [ParticipationEntryBody] {
        let max = week.maxPointsByDate.first { $0.date == date }?.maxPoints ?? 0
        return edits.sorted { $0.key < $1.key }.compactMap { userId, edit in
            let saved = week.pending(userId, date).map { ($0.points, $0.notes) }
                ?? week.entry(userId, date).map { ($0.points, $0.notes) }
            let notes = String(edit.notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxParticipationNotes))
            if let saved, saved.0 == edit.points, saved.1 == notes { return nil }
            return ParticipationEntryBody(userId: userId, date: date, points: min(edit.points, max), notes: notes)
        }
    }

    /// Full marks count at once; anything lower waits for another producer.
    static func isDocked(points: Int, max: Int) -> Bool { points < max }
}

/// A participation cell being edited.
struct ParticipationEdit: Equatable {
    var points: Int
    var notes: String
}

/// `points` for `setCheckIn`: a number, or "UNGRADED" / "EXEMPT".
enum CheckInPoints: Encodable, Equatable, Hashable {
    case points(Int)
    case state(ScoreState)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .points(let points): try container.encode(points)
        case .state(let state): try container.encode(state.rawValue)
        }
    }
}
