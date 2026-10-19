import Foundation

/// `GET api/ideas[?date=YYYY-MM-DD]`: one set of story ideas (nil when there is none for that date,
/// or none at all) and every set's run date, newest first.
struct IdeasPayload: Decodable, Sendable, Equatable {
    let batch: IdeaBatch?
    let runDates: [String]

    /// The set on screen is the newest one (the web's "Past set" tag shows otherwise).
    var isLatest: Bool {
        guard let batch else { return false }
        return batch.runDate == (runDates.first ?? batch.runDate)
    }

    /// The next older set's date, when the set on screen is in the list and has one.
    var olderDate: String? { neighbor(offset: 1) }

    /// The next newer set's date, when the set on screen is in the list and has one.
    var newerDate: String? { neighbor(offset: -1) }

    private func neighbor(offset: Int) -> String? {
        guard let current = batch?.runDate, let index = runDates.firstIndex(of: current) else { return nil }
        let next = index + offset
        return runDates.indices.contains(next) ? runDates[next] : nil
    }
}

struct IdeaBatch: Decodable, Sendable, Equatable {
    /// "2026-10-05" (Pacific day the set was made).
    let runDate: String
    /// How many local stories the set was drawn from.
    let itemCount: Int
    let ideas: [Idea]

    /// One section per category, in the web's order (News, Feature, Commentary); empty ones and
    /// ideas with a category the app doesn't know are left out, as on the web.
    var sections: [IdeaSection] {
        IdeaCategory.allCases.compactMap { category in
            let items = ideas.enumerated()
                .filter { $0.element.category == category.rawValue }
                .map { IdeaSection.Item(id: "\($0.offset)-\($0.element.title)", idea: $0.element) }
            return items.isEmpty ? nil : IdeaSection(category: category, items: items)
        }
    }

    /// "4 ideas from 30 local stories · New every 2 days", the web header's line.
    var summary: String {
        let count = ideas.count == 1 ? "1 idea" : "\(ideas.count) ideas"
        return "\(count) from \(itemCount) local stories · New every \(IdeasFormat.intervalDays) days"
    }
}

struct Idea: Decodable, Sendable, Equatable {
    struct Source: Decodable, Sendable, Equatable {
        let title: String
        let outlet: String
        let url: String

        /// Only web links open (in a Safari sheet).
        var link: URL? {
            guard let url = URL(string: url), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return nil }
            return url
        }
    }

    let title: String
    let pitch: String
    let angle: String
    /// `news`, `feature` or `commentary` (see `IdeaCategory`).
    let category: String
    let sources: [Source]
}

/// The three kinds of package a group pitches.
enum IdeaCategory: String, CaseIterable, Sendable {
    case news, feature, commentary

    var label: String {
        switch self {
        case .news: "News"
        case .feature: "Feature"
        case .commentary: "Commentary"
        }
    }

    /// The web's hint under each section title.
    var hint: String {
        switch self {
        case .news: "Timely and factual"
        case .feature: "People, places and events"
        case .commentary: "An opinion you could argue"
        }
    }
}

struct IdeaSection: Identifiable, Sendable, Equatable {
    struct Item: Identifiable, Sendable, Equatable {
        let id: String
        let idea: Idea
    }

    let category: IdeaCategory
    let items: [Item]

    var id: String { category.rawValue }
}

/// Dates and words for the Ideas page, matching the web.
enum IdeasFormat {
    static let intervalDays = 2

    static let explainer = "New every \(intervalDays) days from Bay Area news and events: a starting point for your pitch, then make the story your own."
    static let note = "A starting point for your pitch, then make the story your own. Written by AI from public headlines, so details can be wrong. Open the linked stories and check the facts before you pitch."

    /// "Monday, October 5" (`long`), "Mon, Oct 5" (`short`) or "October 2026" (`month`).
    enum Style: String { case long = "EEEE, MMMM d", short = "EEE, MMM d", month = "MMMM yyyy" }

    static func runDate(_ key: String, _ style: Style) -> String {
        guard let date = parse(key) else { return key }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = style.rawValue
        return formatter.string(from: date)
    }

    /// Run dates (newest first) grouped by month, for the Past ideas menu.
    static func monthGroups(_ runDates: [String]) -> [(month: String, runDates: [String])] {
        runDates.reduce(into: [(month: String, runDates: [String])]()) { groups, key in
            let month = Self.runDate(key, .month)
            if groups.last?.month == month {
                groups[groups.count - 1].runDates.append(key)
            } else {
                groups.append((month, [key]))
            }
        }
    }

    private static func parse(_ key: String) -> Date? {
        guard IdeasPage.validDate(key) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
}
