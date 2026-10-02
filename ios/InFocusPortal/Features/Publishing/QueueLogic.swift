import Foundation

/// The Publishing Queue's rules, ported from the Portal's `src/lib/publishing-queue.ts`
/// so the app offers only what the server allows. The server still enforces them.
enum QueueLogic {
    /// Manual placement cap. Automatic assignment never stacks: it picks an empty show.
    static let maxPerShow = 2
    static let showFullMessage = "That show already has \(maxPerShow) packages."

    struct Section: Equatable, Identifiable {
        let date: String
        let packages: [QueuePackage]
        var id: String { date }
    }

    /// Packages already on `date`, not counting `excluding` (the one being moved).
    static func occupied(on date: String, in packages: [QueuePackage], excluding rowId: String? = nil) -> Int {
        packages.filter { $0.queuedForShowDate == date && $0.id != rowId }.count
    }

    static func canPlace(on date: String, in packages: [QueuePackage], moving rowId: String) -> Bool {
        if packages.first(where: { $0.id == rowId })?.queuedForShowDate == date { return true }
        return occupied(on: date, in: packages, excluding: rowId) < maxPerShow
    }

    /// A date that has passed and isn't one of the upcoming shows.
    static func isPast(_ date: String?, upcoming: [String], today: String?) -> Bool {
        guard let date, !upcoming.contains(date) else { return false }
        guard let cutoff = today ?? upcoming.first else { return true }
        return date < cutoff
    }

    /// The live list: every upcoming show (empty ones too), then any later
    /// dated packages, then packages without a date. Past dates are left out.
    static func liveSections(_ payload: QueuePayload) -> [Section] {
        let upcoming = payload.upcomingShows.map(\.date)
        var byDate: [String: [QueuePackage]] = Dictionary(uniqueKeysWithValues: upcoming.map { ($0, []) })
        var undated: [QueuePackage] = []
        for package in payload.packages {
            guard let date = package.queuedForShowDate else { undated.append(package); continue }
            if isPast(date, upcoming: upcoming, today: payload.today) { continue }
            byDate[date, default: []].append(package)
        }
        let extra = byDate.keys.filter { !upcoming.contains($0) }.sorted()
        var sections = (upcoming + extra).map { Section(date: $0, packages: byDate[$0] ?? []) }
        if !undated.isEmpty { sections.append(Section(date: unassigned, packages: undated)) }
        return sections
    }

    /// Past air dates that still hold packages, newest first.
    static func pastSections(_ payload: QueuePayload) -> [Section] {
        let upcoming = payload.upcomingShows.map(\.date)
        let past = Dictionary(grouping: payload.packages.filter {
            isPast($0.queuedForShowDate, upcoming: upcoming, today: payload.today)
        }, by: { $0.queuedForShowDate ?? "" })
        return past.keys.sorted(by: >).map { Section(date: $0, packages: past[$0] ?? []) }
    }

    static let unassigned = "unassigned"

    /// "Cycle 2 · Abby, Otto", or "Custom".
    static func subtitle(custom: Bool, cycleNumber: Int, members: [String?]) -> String {
        if custom || cycleNumber == 0 { return "Custom" }
        let names = members.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return names.isEmpty ? "Cycle \(cycleNumber)" : "Cycle \(cycleNumber) · \(names)"
    }

    /// "Wednesday, October 7" for a `YYYY-MM-DD` key (local calendar day, like the web).
    static func showLabel(_ date: String) -> String {
        guard date != unassigned else { return "No show yet" }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return date }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// The YouTube embed snippet website managers paste (`youtubeEmbedCode`).
    static func embedCode(videoId: String) -> String? {
        guard videoId.wholeMatch(of: /[\w-]{11}/) != nil else { return nil }
        return #"<iframe width="560" height="315" src="https://www.youtube.com/embed/\#(videoId)" title="InFocus package" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>"#
    }

    static func watchURL(videoId: String) -> URL? {
        guard videoId.wholeMatch(of: /[\w-]{11}/) != nil else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(videoId)")
    }
}
