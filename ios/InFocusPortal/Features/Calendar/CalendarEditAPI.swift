import Foundation

/// Producers' Master Calendar and The Show calls (the Portal checks the role on every one).
/// DEBUG stub sessions use `CalendarEditAPI.stub`.
struct CalendarEditAPI: Sendable {
    /// `POST api/master-calendar`: the cell's whole HTML. Returns what was stored ("" = cell removed).
    var saveCell: @Sendable (_ date: String, _ content: String) async throws -> String
    /// `POST api/show-roles/anchors` (source "manual" or "random"). Returns the new cell.
    var setAnchors: @Sendable (_ date: String, _ names: [String], _ source: String) async throws -> String
    /// `GET api/show-roles/anchors?date=`: two random eligible anchors.
    var suggestAnchors: @Sendable (_ date: String) async throws -> [String]
    var setPa: @Sendable (_ date: String, _ names: [String]) async throws -> String
    var suggestPa: @Sendable (_ date: String) async throws -> [String]
    /// "" goes back to the rotation.
    var setShowManager: @Sendable (_ date: String, _ name: String) async throws -> ShowManagerResult
    var setCrew: @Sendable (_ date: String, _ role: String, _ names: [String]) async throws -> String
    /// Clears the month's anchors (PA stays). Returns the cells that changed.
    var wipeAnchors: @Sendable (_ month: String) async throws -> [CalendarMonth.Entry]
    var castCounts: @Sendable () async throws -> [CastCount]
    /// Returns how many cells went to the Google Doc.
    var syncDoc: @Sendable (_ month: String) async throws -> Int
    /// `GET api/show-roles/overview[?date=]`: The Show for producers.
    var showOverview: @Sendable (_ date: String?) async throws -> ShowOverview

    static func live(_ client: PortalClient) -> CalendarEditAPI {
        struct Cell: Encodable { let date: String; let content: String }
        struct Saved: Decodable { let content: String?; let deleted: Bool? }
        struct Names: Encodable { let date: String; let names: [String] }
        struct Anchors: Encodable { let date: String; let names: [String]; let source: String }
        struct Manager: Encodable { let date: String; let name: String }
        struct Crew: Encodable { let date: String; let role: String; let names: [String] }
        struct Month: Encodable { let month: String }
        struct Content: Decodable { let content: String? }
        struct Suggestion: Decodable { let suggested: [String]? }
        struct Wiped: Decodable { let entries: [CalendarMonth.Entry]? }
        struct Counts: Decodable { let people: [CastCount] }
        struct Synced: Decodable { let entryCount: Int }
        return CalendarEditAPI(
            saveCell: { day, content in
                let saved: Saved = try await client.post("api/master-calendar", body: Cell(date: day, content: content))
                return saved.deleted == true ? "" : saved.content ?? content
            },
            setAnchors: { day, names, source in
                let saved: Content = try await client.post("api/show-roles/anchors", body: Anchors(date: day, names: names, source: source))
                return saved.content ?? ""
            },
            suggestAnchors: { day in try await client.get("api/show-roles/anchors", query: dateQuery(day), as: Suggestion.self).suggested ?? [] },
            setPa: { day, names in
                let saved: Content = try await client.post("api/show-roles/pa-announcers", body: Names(date: day, names: names))
                return saved.content ?? ""
            },
            suggestPa: { day in try await client.get("api/show-roles/pa-announcers", query: dateQuery(day), as: Suggestion.self).suggested ?? [] },
            setShowManager: { day, name in try await client.post("api/show-roles/show-manager", body: Manager(date: day, name: name)) },
            setCrew: { day, role, names in
                let saved: Content = try await client.post("api/show-roles/crew", body: Crew(date: day, role: role, names: names))
                return saved.content ?? ""
            },
            wipeAnchors: { month in
                let wiped: Wiped = try await client.post("api/show-roles/anchors/wipe", body: Month(month: month))
                return wiped.entries ?? []
            },
            castCounts: { try await client.get("api/master-calendar/cast-counts", as: Counts.self).people },
            syncDoc: { month in try await client.post("api/master-calendar/sync-doc", body: Month(month: month), as: Synced.self).entryCount },
            showOverview: { day in try await client.get("api/show-roles/overview", query: day.map(dateQuery) ?? []) }
        )
    }

    private static func dateQuery(_ key: String) -> [URLQueryItem] { [URLQueryItem(name: "date", value: key)] }

    /// Live, or the DEBUG fixtures when the shell runs on a stub session.
    static func current(_ client: PortalClient) -> CalendarEditAPI {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "InFocusStubSession") != nil { return .stub }
        #endif
        return .live(client)
    }
}

/// `POST api/show-roles/show-manager`.
struct ShowManagerResult: Decodable, Sendable, Equatable {
    let content: String?
    let name: String
    let source: String
    let pool: [String]?
}

/// One row of Anchors & PA counts (`GET api/master-calendar/cast-counts`).
struct CastCount: Decodable, Sendable, Equatable, Identifiable {
    let name: String
    let anchors: Int
    let pa: Int

    var id: String { name }
}

/// The Show for producers (`GET api/show-roles/overview`).
struct ShowOverview: Decodable, Sendable, Equatable {
    struct Manager: Decodable, Sendable, Equatable {
        let name: String
        let source: String
    }

    struct Package: Decodable, Sendable, Equatable, Identifiable {
        let id: String
        let cycleNumber: Int
        let groupTopic: String
        let custom: Bool
        let members: [String]
    }

    struct UpcomingShow: Decodable, Sendable, Equatable, Identifiable {
        let date: String
        let label: String
        let packageCount: Int
        let showManager: String

        var id: String { date }
    }

    let date: String
    let label: String
    /// Everyone pickable on The Show (advisers included).
    let members: [String]
    let roles: [String]
    let anchors: [String]
    let paAnnouncers: [String]
    let assignments: [String: String]
    let showManager: Manager
    let showManagerPool: [String]
    /// Who already anchors another show this month (can't be picked again).
    let monthAnchors: [String]
    let packages: [Package]
    let teleprompterDocId: String?
    let teleprompterHref: String
    let upcomingShows: [UpcomingShow]
}
