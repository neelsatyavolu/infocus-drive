import XCTest
@testable import InFocusPortal

/// Show > Editing: decoding `api/show-roles/edits`, the rules ported from the Portal, the actions
/// sent, and the `/editing` deep link. Fictional data only.
private let portal = URL(string: "https://portal.example.edu")!

private func stubClient() -> PortalClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return PortalClient(portal: portal, session: URLSession(configuration: config), cookies: { [] })
}

private func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
}

private func recording(_ name: String, folder: String? = nil, size: Double = 1e9, minutesAgo: Double = 30, stable: Bool = true) -> ShowEditState.Recording {
    let json = """
    {"path":"Shows/\(folder.map { "\($0)/" } ?? "")\(name)","name":"\(name)","size":\(size),
     "modifiedAt":"\(ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -minutesAgo * 60)))","stable":\(stable),
     "folder":\(folder.map { "\"Shows/\($0)\"" } ?? "null")}
    """
    return try! PortalJSON.decoder().decode(ShowEditState.Recording.self, from: Data(json.utf8))
}

final class ShowEditingTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    // MARK: Decoding

    func testFixtureDecodesWithChaptersAndReviewState() throws {
        let state = try ShowEditFixtures.review(date: "2026-10-28")
        XCTAssertEqual(state.job?.status, "REVIEW")
        XCTAssertEqual(state.job?.checks?.chapters.map(\.title), ["Intro", "Announcements", "Club Fair"])
        XCTAssertFalse(state.sentToYouTube)
        XCTAssertFalse(state.canStart, "an edit under review can't be started again")
        XCTAssertEqual(ShowEditRules.summary(state).label, "Ready for review")
        XCTAssertEqual(ShowEditRules.editorStatus(state).label, "Editor online · Edit Bay · v1.4.0")
    }

    func testChecksAreLenient() throws {
        let json = #"{"chapters":[{"title":"  Welcome  back ","start":12},{"title":"Intro","start":3},{"start":5},"x",{"title":"Bad","start":-1}],"failures":[{"rule":"loudness"},{"detail":"Card cut off","rule":"cards"},7],"coversClean":true}"#
        let checks = try JSONDecoder().decode(ShowEditChecks.self, from: Data(json.utf8))
        XCTAssertEqual(checks.chapters, [ShowChapter(title: "Intro", start: 0), ShowChapter(title: "Welcome back", start: 12)],
                       "sorted, cleaned, the first at 0")
        XCTAssertEqual(checks.failures, ["loudness", "Card cut off"])
    }

    func testUnknownSourceRoleReadsAsAuto() throws {
        let source = try JSONDecoder().decode(ShowEditSource.self, from: Data(#"{"path":"Shows/a.mov","role":"drone"}"#.utf8))
        XCTAssertEqual(source.role, .auto)
    }

    // MARK: Rules

    func testChapterTimes() {
        XCTAssertEqual(ShowChapter.time(75.4), "1:15")
        XCTAssertEqual(ShowChapter.time(3723), "1:02:03")
    }

    func testRecordingNamesAndRoles() {
        XCTAssertEqual(ShowEditRules.showDate(fromName: "InFocus Show 10-22-2026 (2).mov"), "2026-10-22")
        XCTAssertEqual(ShowEditRules.showDate(fromName: "infocus show 10-22-2026 Left.MP4"), "2026-10-22")
        XCTAssertNil(ShowEditRules.showDate(fromName: "InFocus Show.mov"))
        XCTAssertEqual(ShowEditRules.role(fromName: "Shows/InFocus Show 10-22-2026 Center.mov"), .M)
        XCTAssertEqual(ShowEditRules.role(fromName: "InFocus Show 10-22-2026 Right (1).mov"), .R)
        XCTAssertEqual(ShowEditRules.role(fromName: "InFocus Show 10-22-2026.mov"), .auto)
    }

    func testDefaultSelectionMatchesThePortal() {
        let recordings = [
            recording("InFocus Show 10-22-2026 Left.mov", size: 2e9, minutesAgo: 20),
            recording("InFocus Show 10-22-2026 Center.mov", size: 3e9, minutesAgo: 40),
            recording("InFocus Show 10-22-2026 EDITED.mov", size: 4e9, minutesAgo: 10),
            recording("InFocus Show 10-22-2026 (1).mov", size: 5e9, minutesAgo: 1, stable: false),
            recording("InFocus Show 10-21-2026.mov", size: 6e9, minutesAgo: 60),
            recording("InFocus Show 10-22-2026 Right.mov", size: 6e9, minutesAgo: 30),
        ]
        XCTAssertEqual(ShowEditRules.defaultSelection(recordings, showDate: "2026-10-22").map(\.role), [.M, .L],
                       "oldest first; skips edited exports, files still copying, and a copy of another show's file")
        XCTAssertEqual(ShowEditRules.exclusion(recordings[5], in: recordings),
                       "Same size as InFocus Show 10-21-2026.mov: probably a copy of another show")
    }

    func testSelectionEditing() {
        var selected = ShowEditRules.toggle([], path: "Shows/InFocus Show 10-22-2026 Left.mov")
        XCTAssertEqual(selected, [ShowEditSource(path: "Shows/InFocus Show 10-22-2026 Left.mov", role: .L)])
        selected = ShowEditRules.toggle(selected, path: "Shows/b.mov")
        selected = ShowEditRules.move(selected, from: 1, by: -1)
        XCTAssertEqual(selected.map(\.fileName), ["b.mov", "InFocus Show 10-22-2026 Left.mov"])
        selected = ShowEditRules.setRole(selected, path: "Shows/b.mov", role: .ignore)
        XCTAssertNil(ShowEditRules.selectionError(selected))
        selected = ShowEditRules.toggle(selected, path: "Shows/InFocus Show 10-22-2026 Left.mov")
        XCTAssertEqual(ShowEditRules.selectionError(selected), "Every file is set to Ignore. Use at least one.")
        XCTAssertEqual(ShowEditRules.selectionError([]), "Pick at least one recording.")
    }

    func testFolderToggleAddsFinishedFilesThenRemovesThem() {
        let files = [recording("b.mov", folder: "Day", minutesAgo: 10), recording("a.mov", folder: "Day", minutesAgo: 20),
                     recording("c.mov", folder: "Day", minutesAgo: 1, stable: false)]
        let added = ShowEditRules.toggleFolder([], files: files)
        XCTAssertEqual(added.map(\.fileName), ["a.mov", "b.mov"])
        XCTAssertEqual(ShowEditRules.toggleFolder(added, files: files), [])
        let groups = ShowEditRules.groups(files + [recording("loose.mov")])
        XCTAssertEqual(groups.map(\.folder), [nil, "Shows/Day"], "loose files first")
    }

    func testVisibleRecordingsKeepTickedOlderOnes() {
        let files = (0..<9).map { recording("f\($0).mov", minutesAgo: Double($0 * 10 + 5)) }
        let visible = ShowEditRules.visible(files, chosen: ["Shows/f8.mov"], showAll: false)
        XCTAssertEqual(visible.shown.count, 7)
        XCTAssertEqual(visible.hidden, 2)
    }

    func testPublishSlotOnlyWhenChanged() {
        let usual = ShowEditRules.usualPublishDate(showDate: "2026-10-28")
        XCTAssertNil(ShowEditRules.publishSlot(usual, showDate: "2026-10-28"))
        XCTAssertEqual(ShowEditRules.publishSlot(usual.addingTimeInterval(3600), showDate: "2026-10-28"),
                       .init(date: "2026-10-28", time: "09:30"))
    }

    func testNotesAndLines() {
        XCTAssertTrue(ShowEditRules.packageNote([]).warning)
        XCTAssertEqual(ShowEditRules.packageNote([.init(title: "Gas", ready: false)]).text,
                       "“Gas” is queued but has no final cut uploaded, so the editor can't use it. Upload the final cut in the Publishing Queue first.")
        XCTAssertEqual(ShowEditRules.announcementNote(1).text, "1 announcement in the show's script (A2).")
        XCTAssertTrue(ShowEditRules.announcementNote(nil).warning)
        XCTAssertEqual(ShowEditRules.approveLine(.init(title: "T", publishAt: "2026-10-28T15:30:00.000Z", problem: "No season.")), "No season.")
        XCTAssertTrue(ShowEditRules.approveLine(.init(title: "T", publishAt: "2026-10-28T15:30:00.000Z", problem: nil)).contains("8:30"))
        XCTAssertEqual(ShowEditRules.lastSeen(Date(timeIntervalSinceNow: -12 * 60)), "12 min ago")
    }

    // MARK: Network

    func testStateAndActionsMatchThePortal() async throws {
        StubProtocol.handler = { request in
            if request.httpMethod == "GET" {
                let body = try! JSONSerialization.data(withJSONObject: ["data": ["worker": ["online": false, "busy": false],
                    "devices": [], "settings": ["autoStart": true], "pairings": [], "recordings": [], "packages": [],
                    "announcements": NSNull(), "job": NSNull(), "publicationStatus": NSNull()]])
                return (200, body)
            }
            return (200, Data(#"{"data":{"ok":true}}"#.utf8))
        }
        let api = ShowEditAPI.live(stubClient())
        let state = try await api.state("2026-10-28")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.query, "date=2026-10-28")
        XCTAssertTrue(state.canStart)
        XCTAssertEqual(ShowEditRules.editorStatus(state).label, "No editor linked")

        try await api.send(.start(date: "2026-10-28", sources: [.init(path: "Shows/a.mov", role: .M)], note: "Later take",
                                  publish: .init(date: "2026-10-28", time: "09:00")))
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/show-roles/edits")
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as NSDictionary, [
            "action": "start", "date": "2026-10-28", "sources": [["path": "Shows/a.mov", "role": "M"]],
            "note": "Later take", "publish": ["date": "2026-10-28", "time": "09:00"],
        ])

        try await api.send(.start(date: "2026-10-28", sources: [], note: nil, publish: nil))
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as NSDictionary, ["action": "start", "date": "2026-10-28", "sources": []],
                       "no note or publish time when none was given")

        try await api.send(.approve(id: "job1", publishAt: "2026-10-28T15:30:00.000Z"))
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as NSDictionary,
                       ["action": "approve", "id": "job1", "publishAt": "2026-10-28T15:30:00.000Z"])

        try await api.send(.fix(id: "job1", text: "At 1:12 the card is cut off.", remember: true))
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as NSDictionary,
                       ["action": "fix", "id": "job1", "text": "At 1:12 the card is cut off.", "remember": true])
    }

    // MARK: Deep links

    func testEditingDeepLinks() {
        func route(_ path: String) -> Route? { DeepLink.resolve(URL(string: "https://portal.example.edu/\(path)")!, portal: portal).route }
        XCTAssertEqual(route("editing"), .calendar(.editing(date: nil)))
        XCTAssertEqual(route("editing?date=2026-10-28"), .calendar(.editing(date: "2026-10-28")))
        XCTAssertEqual(route("editing?date=nope"), .calendar(.editing(date: nil)))
        XCTAssertEqual(route("editing?view=show&date=2026-10-28"), .calendar(.editing(date: "2026-10-28")))
        for web in ["editing?view=machines", "editing?view=settings", "editing?view=howto", "editing?link=ABCD2345"] {
            guard case .portal? = route(web) else { return XCTFail("/\(web) should stay a web page") }
        }
    }
}
