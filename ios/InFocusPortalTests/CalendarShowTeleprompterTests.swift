import XCTest
@testable import InFocusPortal

/// Master Calendar notes and package pills, the show upload and the teleprompter. Fictional data only.
private let portal = URL(string: "https://portal.example.edu")!

private func stubClient() -> PortalClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return PortalClient(portal: portal, session: URLSession(configuration: config), cookies: { [] })
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
}

private func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
}

// MARK: - Master Calendar notes

final class CalendarNotesTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    private let cell = "[[NO_MONDAY_IMAGE]]<p>Club Fair at lunch</p>"
        + "<p><span class=\"package-pill\" data-package-id=\"m1\" data-display-label=\"Gas &amp; Prices\">Gas &amp; Prices</span></p>"
        + "<p>Bring <strong>IDs</strong></p><p><span class=\"package-pill\" data-package-id=\"m2\">Puppy Yoga</span></p>"

    func testParseSplitsTextPillsAndImageToken() {
        let notes = CalendarNotes.parse(cell)
        XCTAssertTrue(notes.imageHidden)
        XCTAssertEqual(notes.text, "Club Fair at lunch\nBring IDs")
        XCTAssertEqual(notes.pills, [.init(id: "m1", label: "Gas & Prices"), .init(id: "m2", label: "Puppy Yoga")],
                       "an older pill without a display label keeps its text")
    }

    func testHtmlRebuildsTheCellLikeThePortal() {
        let notes = CalendarNotes(text: "Assembly\n\n  Rally <7th> ", pills: [.init(id: "m1", label: "Club \"Fair\"")], imageHidden: true)
        XCTAssertEqual(notes.html(), "[[NO_MONDAY_IMAGE]]<p>Assembly</p><p>Rally &lt;7th&gt;</p>"
                       + "<p><span class=\"package-pill\" data-package-id=\"m1\" data-display-label=\"Club &quot;Fair&quot;\">Club &quot;Fair&quot;</span></p>")
        XCTAssertEqual(CalendarNotes(text: "", pills: [], imageHidden: true).html(), "[[NO_MONDAY_IMAGE]]", "image off on an empty day")
        XCTAssertEqual(CalendarNotes(text: "", pills: [], imageHidden: false).html(), "", "an empty cell is removed")
        XCTAssertEqual(CalendarNotes.parse(notes.html()), CalendarNotes(text: "Assembly\nRally <7th>", pills: notes.pills, imageHidden: true))
    }

    func testAiredChangesAndTokenStripping() {
        let changes = CalendarNotes.airedChanges(before: cell, after: CalendarNotes.pillHTML(id: "m2", label: "x") + CalendarNotes.pillHTML(id: "m3", label: "y"))
        XCTAssertEqual(changes.added, ["m3"])
        XCTAssertEqual(changes.removed, ["m1"])
        XCTAssertEqual(CalendarNotes.stripToken("[[NO_MONDAY_IMAGE]]<p>Hi</p>"), "<p>Hi</p>")
    }

    func testScenicImageMatchesThePortalHash() {
        XCTAssertEqual(CalendarNotes.scenicImage(for: "2026-10-05")?.absoluteString, CalendarNotes.scenicImages[4])
        XCTAssertEqual(CalendarNotes.scenicImage(for: "2026-10-06")?.absoluteString, CalendarNotes.scenicImages[5])
        XCTAssertEqual(CalendarNotes.scenicImage(for: "2026-11-02")?.absoluteString, CalendarNotes.scenicImages[2])
    }

    func testDayNotesHideTheImageToken() {
        let month = CalendarMonth(month: "2026-10", canEdit: true, entries: [.init(date: "2026-10-06", content: "[[NO_MONDAY_IMAGE]]<p>Assembly</p>")],
                                  schedule: [.init(date: "2026-10-06", kind: .none, label: "")], queuedPackages: [], showManagers: [:])
        XCTAssertEqual(CalendarStore.days(from: month).first?.notes, ["Assembly"])
    }

    func testPackageSearchAndAiredCalls() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"data":{"results":[{"id":"m1","title":"Club Fair","projectId":"p1","projectName":"Cycle 2","currentVersionId":"v1","approvalStatus":"APPROVED","airedAt":null}]}}"#.utf8))
        }
        let api = CalendarEditAPI.live(stubClient())
        let results = try await api.searchPackages("club")
        XCTAssertEqual(results, [CalendarPackageOption(id: "m1", title: "Club Fair", projectName: "Cycle 2", approvalStatus: "APPROVED", airedAt: nil)])
        XCTAssertEqual(results.first?.statusLabel, "Approved")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/master-calendar/packages")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.query, "q=club")

        StubProtocol.handler = { _ in (200, Data(#"{"data":{"reverted":true}}"#.utf8)) }
        try await api.markAired("m1", "2026-10-06")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/master-calendar/mark-aired")
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as NSDictionary, ["mediaItemId": "m1", "date": "2026-10-06"])
        try await api.unmarkAired("m1")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/master-calendar/unmark-aired")
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as NSDictionary, ["mediaItemId": "m1"])
    }
}

@MainActor
final class CalendarNotesEditorTests: XCTestCase {
    private actor Calls {
        var cells: [String] = []
        var marked: [String] = []
        var unmarked: [String] = []
        func save(_ content: String) { cells.append(content) }
        func mark(_ id: String) { marked.append(id) }
        func unmark(_ id: String) { unmarked.append(id) }
    }

    private func read(_ content: String, kind: DayKind = .none) -> CalendarAPI {
        var api = CalendarAPI.stub
        let month = CalendarMonth(month: "2026-10", canEdit: true, entries: [.init(date: "2026-10-06", content: content)],
                                  schedule: [.init(date: "2026-10-06", kind: kind, label: "")], queuedPackages: [], showManagers: [:])
        api.month = { _ in month }
        return api
    }

    private func edit(_ calls: Calls) -> CalendarEditAPI {
        var edit = CalendarEditAPI.stub
        edit.saveCell = { _, content in await calls.save(content); return content }
        edit.markAired = { id, _ in await calls.mark(id) }
        edit.unmarkAired = { id in await calls.unmark(id) }
        return edit
    }

    func testNotesKeepTheImageTokenAndSyncAiredPills() async {
        let calls = Calls()
        let before = "[[NO_MONDAY_IMAGE]]<p>Old</p><p>" + CalendarNotes.pillHTML(id: "m1", label: "Club Fair") + "</p>"
        let editor = CalendarDayEditor(date: "2026-10-06", edit: edit(calls), read: read(before), store: CalendarStore())
        await editor.setNotes("New", pills: [.init(id: "m2", label: "Gas Prices")])
        let cells = await calls.cells
        let marked = await calls.marked
        let unmarked = await calls.unmarked
        XCTAssertEqual(cells, ["[[NO_MONDAY_IMAGE]]<p>New</p><p>" + CalendarNotes.pillHTML(id: "m2", label: "Gas Prices") + "</p>"])
        XCTAssertEqual(marked, ["m2"])
        XCTAssertEqual(unmarked, ["m1"])
        XCTAssertNil(editor.error)
    }

    func testToggleImageKeepsTheNotes() async {
        let calls = Calls()
        let editor = CalendarDayEditor(date: "2026-10-06", edit: edit(calls), read: read("<p>Assembly</p>"), store: CalendarStore())
        await editor.toggleImage()
        let cells = await calls.cells
        let marked = await calls.marked
        XCTAssertEqual(cells, ["[[NO_MONDAY_IMAGE]]<p>Assembly</p>"])
        XCTAssertEqual(marked, [], "no pills changed")
    }
}

// MARK: - Show upload

final class ShowUploadTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    private let draftJSON = """
    {"data":{"showDate":"2026-10-21","configured":true,"publication":{"status":"DRAFT","title":"InFocus News","description":"",
     "publishAt":"2026-10-21T15:30:00.000Z","seasonNumber":null,"uploadedBytes":null,"totalBytes":null,"watchUrl":null,"lastError":null},
     "defaults":{"title":"InFocus News | October 21","description":"Anchors: Abby & Otto","publishDate":"2026-10-21","publishTime":"08:30",
     "seasonNumber":3,"existingSeasons":[3,2,1]}}}
    """

    func testDecodesDraftAndSentStates() throws {
        let draft = try decode(ShowUploadState.self, draftJSON)
        XCTAssertFalse(draft.isSent)
        XCTAssertEqual(draft.defaults?.existingSeasons, [3, 2, 1])
        XCTAssertEqual(ShowUploadForm(try XCTUnwrap(draft.defaults)).seasonNumber, "3")

        let sent = try decode(ShowUploadState.self, """
        {"data":{"showDate":"2026-10-21","configured":true,"defaults":null,"publication":{"status":"UPLOADING","title":"InFocus News",
         "description":"","publishAt":"2026-10-21T15:30:00Z","seasonNumber":3,"uploadedBytes":50,"totalBytes":200,
         "watchUrl":"https://video.example.edu/watch?v=abc","lastError":null}}}
        """)
        XCTAssertTrue(sent.isSent)
        XCTAssertNil(sent.defaults)
        XCTAssertEqual(ShowUploadRules.percent(uploaded: sent.publication?.uploadedBytes, total: sent.publication?.totalBytes), 25)
        XCTAssertTrue(ShowUploadRules.active.contains(sent.publication?.status ?? ""))
    }

    func testFormRulesMatchThePortal() {
        var form = ShowUploadForm(title: " Show ", description: "Credits", publishDate: "2026-10-21", publishTime: "08:30", seasonNumber: "3")
        XCTAssertNil(form.problem)
        XCTAssertEqual(form.confirmBody(showDate: "2026-10-21"),
                       .init(showDate: "2026-10-21", title: "Show", description: "Credits", publishDate: "2026-10-21",
                             publishTime: "08:30", seasonNumber: 3))
        form.title = "<b>"
        XCTAssertEqual(form.problem, "No < or > in the title.")
        form.title = String(repeating: "a", count: 101)
        XCTAssertNotNil(form.problem)
        form.title = "Show"
        form.seasonNumber = "0"
        XCTAssertEqual(form.problem, "Enter a season number.")
        XCTAssertNil(form.confirmBody(showDate: "2026-10-21"))
        form.seasonNumber = "4"
        form.publishTime = "24:00"
        XCTAssertEqual(form.problem, "Pick the time it goes public.")
    }

    func testPublishMomentIsPacific() throws {
        var form = ShowUploadForm(title: "Show", description: "", publishDate: "2026-10-21", publishTime: "08:30", seasonNumber: "3")
        let moment = try XCTUnwrap(form.publishAt)
        XCTAssertEqual(ISO8601DateFormatter().string(from: moment), "2026-10-21T15:30:00Z")
        form.setPublishAt(moment.addingTimeInterval(86_400 + 1_800))
        XCTAssertEqual([form.publishDate, form.publishTime], ["2026-10-22", "09:00"])
    }

    func testSeasonHint() {
        XCTAssertEqual(ShowUploadRules.seasonHint(existing: [3, 2], season: "4"), "New playlist: \"InFocus News | Season 4\" will be created.")
        XCTAssertEqual(ShowUploadRules.seasonHint(existing: [3, 2], season: "3"), "Adds to the existing playlist.")
        XCTAssertEqual(ShowUploadRules.seasonHint(existing: nil, season: "3"), "Couldn't read playlists from YouTube. Check the number.")
    }

    func testLiveCalls() async throws {
        let api = ShowUploadAPI.live(stubClient())
        StubProtocol.handler = { _ in
            (200, Data(#"{"data":{"upload":{"provider":"NAS","uploadUrl":"https://drive.example.edu/api/upload","path":"shows/2026-10-21/show.mov","token":"t"}}}"#.utf8))
        }
        let drive = try await api.start("2026-10-21", "show.mov")
        XCTAssertEqual(drive.path, "shows/2026-10-21/show.mov")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/show-roles/publication")
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as NSDictionary, ["action": "init", "showDate": "2026-10-21", "fileName": "show.mov"])

        StubProtocol.handler = { _ in (200, Data(#"{"data":{"saved":true}}"#.utf8)) }
        try await api.savePoster("2026-10-21", Data([0xFF, 0xD8]))
        let poster = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(poster.url?.path, "/api/show-roles/publication/poster")
        XCTAssertTrue(poster.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let text = String(decoding: poster.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"showDate\"\r\n\r\n2026-10-21"))
        XCTAssertTrue(text.contains("filename=\"poster.jpg\"\r\nContent-Type: image/jpeg"))

        StubProtocol.handler = { [draftJSON] _ in (200, Data(draftJSON.utf8)) }
        _ = try await api.confirm(.init(showDate: "2026-10-21", title: "Show", description: "", publishDate: "2026-10-21",
                                        publishTime: "08:30", seasonNumber: 3))
        let body = try jsonBody(StubProtocol.lastRequest)
        XCTAssertEqual(body["action"] as? String, "confirm")
        XCTAssertEqual(body["seasonNumber"] as? Int, 3)
    }

    @MainActor
    func testUploadThenScheduleFlow() async throws {
        let draft = try decode(ShowUploadState.self, draftJSON)
        let scheduled = ShowUploadState(showDate: "2026-10-21", configured: true, publication: .init(
            status: "SCHEDULED", title: "Show", publishAt: Date(), seasonNumber: 3, uploadedBytes: nil, totalBytes: nil,
            watchUrl: nil, lastError: nil))
        let api = ShowUploadAPI(
            state: { _ in draft },
            start: { _, _ in DriveUploadSession(provider: "NAS", uploadUrl: URL(string: "https://drive.example.edu/api/upload")!, path: "p", token: "t") },
            send: { _, _, progress in await progress(0.5) },
            savePoster: { _, _ in },
            confirm: { body in
                XCTAssertEqual(body.title, "InFocus News | October 21")
                return scheduled
            }
        )
        let model = ShowUploadModel(date: "2026-10-21", api: api)
        await model.load()
        XCTAssertEqual(model.phase, .pick)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("show-test.mov")
        try Data("not a video".utf8).write(to: file)
        await model.upload(file, fileName: "show.mov")
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.form?.publishTime, "08:30")
        await model.schedule()
        XCTAssertEqual(model.phase, .status)
        XCTAssertEqual(model.state?.publication?.status, "SCHEDULED")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the temporary copy is removed")
    }

    @MainActor
    func testForbiddenReadsAsNotAvailable() async {
        var api = ShowUploadAPI.stub
        api.state = { _ in throw PortalError.forbidden("Nope") }
        let model = ShowUploadModel(date: "2026-10-21", api: api)
        await model.load()
        XCTAssertEqual(model.phase, .failed("Show uploads are for producers."))
    }
}

// MARK: - Teleprompter

final class TeleprompterTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    static let payloadJSON = """
    {"data":{"workspaceId":"w1","canEdit":true,"nextShowDateIso":"2026-10-21T12:00:00.000Z","autofill":{"status":"warning","message":"Bulletin not found."},
     "docs":[
      {"id":"d1","title":"InFocus Show - Oct 14","orderIndex":0,"showDate":"2026-10-14T12:00:00.000Z","createdAt":"2026-10-10T18:00:00.000Z","updatedAt":"2026-10-10T18:00:00.000Z",
       "sections":[{"id":"s1","label":"A1","content":"OPEN\\n\\nANCHOR: Hi","orderIndex":0,"createdAt":"2026-10-10T18:00:00.000Z","updatedAt":"2026-10-10T18:00:00.000Z"}]},
      {"id":"d2","title":"InFocus Show - Oct 21","orderIndex":1,"showDate":"2026-10-21T12:00:00.000Z","createdAt":"2026-10-17T18:00:00.000Z","updatedAt":"2026-10-17T18:00:00.000Z",
       "sections":[{"id":"s2","label":"A3","content":"PACKAGE\\nANCHOR: [INSERT PACKAGE TOSS]","orderIndex":0,"createdAt":"2026-10-17T18:00:00.000Z","updatedAt":"2026-10-17T18:00:00.000Z"}]},
      {"id":"d3","title":"Practice","orderIndex":2,"showDate":null,"createdAt":"2026-09-01T18:00:00.000Z","updatedAt":"2026-09-01T18:00:00.000Z","sections":[]}
     ]}}
    """

    func testDecodesPayloadAndPicksTheScript() throws {
        let payload = try decode(TeleprompterPayload.self, Self.payloadJSON)
        XCTAssertEqual(payload.autofill.status, "warning")
        XCTAssertEqual(TeleprompterScript.sorted(payload.docs).map(\.id), ["d2", "d1", "d3"])
        XCTAssertEqual(TeleprompterScript.initial(payload.docs, docId: "d3", showDate: nil, nextShowIso: payload.nextShowDateIso)?.id, "d3")
        XCTAssertEqual(TeleprompterScript.initial(payload.docs, docId: nil, showDate: "2026-10-14", nextShowIso: payload.nextShowDateIso)?.id, "d1")
        XCTAssertEqual(TeleprompterScript.initial(payload.docs, docId: "gone", showDate: nil, nextShowIso: payload.nextShowDateIso)?.id, "d2")
        let rename = try decode(TeleprompterDocTitle.self,
                                #"{"data":{"id":"d1","title":"New","orderIndex":0,"createdAt":"2026-10-10T18:00:00.000Z","updatedAt":"2026-10-10T18:00:00.000Z"}}"#)
        XCTAssertEqual(rename, TeleprompterDocTitle(id: "d1", title: "New"))
    }

    func testSectionDisplayAndStatuses() throws {
        let payload = try decode(TeleprompterPayload.self, Self.payloadJSON)
        let parts = TeleprompterScript.displayParts(label: "A1", content: "OPEN\n\nANCHOR: Hi")
        XCTAssertEqual(parts.badge, "A1 - Open")
        XCTAssertEqual(parts.content, "ANCHOR: Hi")
        XCTAssertEqual(TeleprompterScript.displayParts(label: "A2", content: "Club news").badge, "A2", "only beat headings move")
        XCTAssertEqual(TeleprompterScript.status(of: payload.docs[1].sections[0]), "To fill")
        XCTAssertEqual(TeleprompterScript.status(of: .init(id: "x", label: "A1", content: "OPEN\n", orderIndex: 0, createdAt: Date(), updatedAt: Date())), "Empty")
        XCTAssertEqual(TeleprompterScript.docStatus(payload.docs[1], today: "2026-10-18", nextShow: "2026-10-21")?.label, "Next show")
        XCTAssertEqual(TeleprompterScript.docStatus(payload.docs[1], today: "2026-10-21", nextShow: nil)?.label, "Today")
        XCTAssertEqual(TeleprompterScript.docStatus(payload.docs[1], today: "2026-10-18", nextShow: nil)?.label, "To fill · 1")
        XCTAssertEqual(TeleprompterScript.docStatus(payload.docs[2], today: "2026-10-18", nextShow: nil)?.label, "No sections")
        let runs = TeleprompterScript.placeholderRuns("Hi [INSERT THANK YOU NAMES] bye")
        XCTAssertEqual(runs.map(\.placeholder), [false, true, false])
        XCTAssertEqual(runs[1].text, "[INSERT THANK YOU NAMES]")
    }

    func testRunLinesClassifyLikeTheWeb() {
        XCTAssertEqual(RunScriptLine.classify("  "), .gap)
        XCTAssertEqual(RunScriptLine.classify("cam  2"), .camera("CAM 2"))
        XCTAssertEqual(RunScriptLine.classify("Anchor: Good morning"), .cue("ANCHOR", spoken: "Good morning"))
        XCTAssertEqual(RunScriptLine.classify("co-anchor - Hi"), .cue("COANCHOR", spoken: "Hi"))
        XCTAssertEqual(RunScriptLine.classify("CAM 1: wide"), .camera("CAM 1"))
        XCTAssertEqual(RunScriptLine.classify("{roll  package}"), .cue("ROLL PACKAGE", spoken: nil))
        XCTAssertEqual(RunScriptLine.classify("[HOLD]"), .cue("HOLD", spoken: nil))
        XCTAssertEqual(RunScriptLine.classify("Bulletin"), .cue("BULLETIN", spoken: nil))
        XCTAssertEqual(RunScriptLine.classify("Club Fair is Thursday."), .spoken("Club Fair is Thursday."))
        let segments = RunScriptLine.segments("Bring [RED]your ID[/RED] and [yellow]a pen[/YELLOW] [RED]x[/YELLOW]")
        XCTAssertEqual(segments.map(\.tone), [.plain, .red, .plain, .yellow, .plain, .plain])
        XCTAssertEqual(segments[1].text, "your ID")
        XCTAssertEqual(segments[5].text, "[RED]x[/YELLOW]", "mismatched tags stay as typed")
    }

    func testPlaybackFollowsTheWebKeys() {
        var playback = TeleprompterPlayback()
        XCTAssertEqual(playback.speed, 72)
        playback = playback.applying(.toggle)
        XCTAssertEqual(playback, TeleprompterPlayback(paused: true, speed: 72), "Space keeps the speed")
        playback = playback.applying(.faster)
        XCTAssertEqual(playback, TeleprompterPlayback(paused: false, speed: 36), "an arrow after a pause restarts from 0")
        playback = playback.applying(.slower).applying(.slower)
        XCTAssertEqual(playback.speed, -36)
        XCTAssertEqual(playback.label, "REV 36")
        XCTAssertEqual(playback.applying(.forward).speed, 36)
        XCTAssertEqual(TeleprompterPlayback(paused: false, speed: 72).applying(.back).speed, -72)
        XCTAssertEqual(TeleprompterPlayback(paused: false, speed: 640).applying(.faster).speed, 640)
        let moving = TeleprompterPlayback(paused: false, speed: 100)
        XCTAssertEqual(moving.advance(10, seconds: 0.5, maxPosition: 1000), 60)
        XCTAssertEqual(moving.advance(990, seconds: 0.5, maxPosition: 1000), 1000)
        XCTAssertEqual(TeleprompterPlayback(paused: false, speed: -100).advance(10, seconds: 0.5, maxPosition: 1000), 0)
        XCTAssertEqual(TeleprompterPlayback(paused: true, speed: 100).advance(10, seconds: 0.5, maxPosition: 1000), 10)
    }

    func testRunLayout() {
        let phone = TeleprompterRunLayout.sizes(width: 400, settings: .init())
        XCTAssertEqual(phone.body, 40, "a phone hits the minimum")
        XCTAssertEqual(TeleprompterRunLayout.sizes(width: 3000, settings: .init(bodyScale: 0.5, cueScale: 1)).body, 49.6, accuracy: 0.01)
        let tops: [String: CGFloat] = ["a": 0, "b": 300, "c": 700]
        XCTAssertEqual(TeleprompterRunLayout.section(at: 0, tops: tops, order: ["a", "b", "c"]), "a")
        XCTAssertEqual(TeleprompterRunLayout.section(at: 290, tops: tops, order: ["a", "b", "c"]), "b")
        XCTAssertEqual(TeleprompterRunLayout.section(at: 2000, tops: tops, order: ["a", "b", "c"]), "c")
    }

    func testRunSettingsAreClampedAndSaved() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "teleprompter-tests"))
        defaults.removePersistentDomain(forName: "teleprompter-tests")
        XCTAssertEqual(TeleprompterRunSettings.load(defaults), TeleprompterRunSettings())
        TeleprompterRunSettings(bodyScale: 3, cueScale: 0.1, mirror: true).save(defaults)
        XCTAssertEqual(TeleprompterRunSettings.load(defaults), TeleprompterRunSettings(bodyScale: 1.3, cueScale: 0.7, mirror: true))
    }

    func testLiveCallsUseThePortalRoutes() async throws {
        let api = TeleprompterAPI.live(stubClient())
        let sectionJSON = #"{"data":{"id":"s1","label":"A1","content":"Hi","orderIndex":0,"createdAt":"2026-10-10T18:00:00.000Z","updatedAt":"2026-10-10T18:00:00.000Z"}}"#
        StubProtocol.handler = { _ in (200, Data(Self.payloadJSON.utf8)) }
        _ = try await api.load("2026-10-21")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.query, "showDate=2026-10-21")

        StubProtocol.handler = { _ in (201, Data(sectionJSON.utf8)) }
        _ = try await api.addSection("d1", "A1", "Hi")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/teleprompter/docs/d1/sections")
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as NSDictionary, ["label": "A1", "content": "Hi"])
        _ = try await api.updateSection("s1", "A1", "Hello")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/teleprompter/sections/s1")
        _ = try await api.sectionJob("s1", .refetch)
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/teleprompter/sections/s1/refetch")

        StubProtocol.handler = { _ in (200, Data(#"{"data":{"id":"s1"}}"#.utf8)) }
        try await api.deleteSection("s1")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "DELETE")
        try await api.deleteDoc("d1")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/teleprompter/docs/d1")

        StubProtocol.handler = { _ in (201, Data(#"{"data":{"id":"d9","title":"Practice","orderIndex":3,"showDate":null,"createdAt":"2026-10-18T18:00:00.000Z","updatedAt":"2026-10-18T18:00:00.000Z","sections":[]}}"#.utf8)) }
        let created = try await api.createDoc("w1", "Practice")
        XCTAssertEqual(created.id, "d9")
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as NSDictionary, ["workspaceId": "w1", "title": "Practice"])
    }

    @MainActor
    func testModelEditsTheSelectedScript() async throws {
        let payload = try decode(TeleprompterPayload.self, Self.payloadJSON)
        var api = TeleprompterAPI.stub
        api.load = { _ in payload }
        api.addSection = { _, label, content in TeleprompterStubData.section("new", label, content) }
        api.deleteDoc = { _ in }
        let model = TeleprompterModel(api: api, showDate: nil, docId: nil)
        await model.load()
        XCTAssertEqual(model.selectedId, "d2", "the next show's script opens first")
        XCTAssertEqual(model.nextLabel(), "A2")
        let saved = await model.saveSection(id: nil, label: "  ", content: "x")
        XCTAssertFalse(saved)
        XCTAssertEqual(model.error, "Give the section a label, like A1.")
        let added = await model.saveSection(id: nil, label: "A2", content: "Club news")
        XCTAssertTrue(added)
        XCTAssertEqual(model.selected?.sections.map(\.label), ["A3", "A2"])
        await model.deleteDoc("d2")
        XCTAssertEqual(model.selectedId, "d1")
        XCTAssertEqual(model.docs.map(\.id), ["d1", "d3"])
    }

    @MainActor
    func testForbiddenReadsAsNotAvailable() async {
        var api = TeleprompterAPI.stub
        api.load = { _ in throw PortalError.forbidden("Nope") }
        let model = TeleprompterModel(api: api, showDate: nil, docId: nil)
        await model.load()
        guard case .failed(let message) = model.state else { return XCTFail("expected a failure") }
        XCTAssertEqual(message, "The teleprompter isn't available for this account.")
    }
}

// MARK: - Deep links

final class CalendarShowDeepLinkTests: XCTestCase {
    private func resolve(_ string: String) -> DeepLinkMatch { DeepLink.resolve(URL(string: string)!, portal: portal) }

    func testTeleprompterLinks() {
        XCTAssertEqual(resolve("https://portal.example.edu/teleprompter?showDate=2026-10-21&doc=d1"),
                       DeepLinkMatch(tab: .calendar, route: .calendar(.teleprompter(showDate: "2026-10-21", docId: "d1"))))
        XCTAssertEqual(resolve("https://portal.example.edu/teleprompter?showDate=soon"),
                       DeepLinkMatch(tab: .calendar, route: .calendar(.teleprompter(showDate: nil, docId: nil))), "a bad date is dropped")
        XCTAssertEqual(resolve("https://teleprompter.portal.example.edu/").route, .calendar(.teleprompter(showDate: nil, docId: nil)))
        XCTAssertEqual(resolve("https://teleprompter.portal.example.edu/teleprompter?doc=d2").route,
                       .calendar(.teleprompter(showDate: nil, docId: "d2")))
        XCTAssertEqual(CalendarRoute.teleprompter(href: "/teleprompter?showDate=2026-10-21&doc=d1"),
                       .teleprompter(showDate: "2026-10-21", docId: "d1"))
        XCTAssertEqual(CalendarRoute.teleprompter(href: "/teleprompter?showDate=2026-10-21"), .teleprompter(showDate: "2026-10-21", docId: nil))
    }

    func testOtherCalendarLinksStillResolve() {
        XCTAssertEqual(resolve("https://portal.example.edu/master-calendar?date=2026-10-07").route, .calendar(.day(date: "2026-10-07")))
        XCTAssertEqual(resolve("https://portal.example.edu/show-roles?date=2026-10-21").route, .calendar(.theShow))
    }
}
