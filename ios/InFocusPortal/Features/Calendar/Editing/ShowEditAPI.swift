import Foundation

/// Automatic editing for one show (producers), as the Portal's Editing tab calls it.
struct ShowEditAPI: Sendable {
    /// `GET api/show-roles/edits?date=`.
    var state: @Sendable (_ date: String) async throws -> ShowEditState
    /// `POST api/show-roles/edits` with one action (start, cancel, redo, fix, approve).
    var send: @Sendable (_ action: ShowEditAction) async throws -> Void

    static func live(_ client: PortalClient) -> ShowEditAPI {
        ShowEditAPI(
            state: { date in
                try await client.get("api/show-roles/edits", query: [URLQueryItem(name: "date", value: date)])
            },
            send: { action in try await client.post("api/show-roles/edits", body: action) }
        )
    }

    /// Live, or the fictional fixtures in the sample app (`SampleMode`).
    static func current(_ client: PortalClient) -> ShowEditAPI {
        if SampleMode.isOn { return .stub }
        return .live(client)
    }

    /// Sample app and screenshots: an edit waiting for review that can't be changed.
    static let stub = ShowEditAPI(
        state: { date in try ShowEditFixtures.review(date: date) },
        send: { _ in
            SampleMode.notSaved()
            throw EditError(SampleMode.notice)
        }
    )
}

/// Fictional automatic-editing data for the sample app and tests.
enum ShowEditFixtures {
    static func review(date: String) throws -> ShowEditState {
        let parts = date.split(separator: "-")
        let name = parts.count == 3 ? "InFocus Show \(parts[1])-\(parts[2])-\(parts[0]).mov" : "InFocus Show.mov"
        let json = """
        {"worker":{"online":true,"lastSeenAt":"2026-10-27T15:00:00Z","busy":false,"version":"v1.4.0","health":{"ok":true,"problems":[]}},
         "devices":[{"id":"d1","name":"Edit Bay","kind":"dedicated","active":true,"online":true}],
         "waitingFor":null,"settings":{"autoStart":false,"autoPublish":false},"commands":[],"pairings":[],
         "recordings":[{"path":"Shows/\(name)","name":"\(name)","size":4200000000,"modifiedAt":"2026-10-27T14:10:00Z","stable":true,"folder":null}],
         "recordingsError":null,"packages":[{"title":"Club Fair","ready":true}],"announcements":4,
         "job":{"id":"job1","showDate":"\(date)","status":"REVIEW","stage":null,"message":null,"note":null,"publishAt":null,
                "decisions":[{"kind":"package","detail":"Used the Club Fair final cut.","flagged":false},
                             {"kind":"structure","detail":"1 recording: switched program.","flagged":false}],
                "checks":{"chapters":[{"title":"Intro","start":0},{"title":"Announcements","start":42},{"title":"Club Fair","start":180}]},
                "costUsd":1.24,"error":null,"cancelRequested":false,"pendingFix":null,"conversation":[],"version":1,
                "finishedAt":"2026-10-27T14:40:00Z"},
         "publicationStatus":"DRAFT","preview":null,"published":null,
         "approve":{"title":"InFocus News | Sample show","publishAt":"2026-10-28T15:30:00.000Z","problem":null},"autoStart":null}
        """
        return try PortalJSON.decoder().decode(ShowEditState.self, from: Data(json.utf8))
    }
}
