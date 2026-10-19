import XCTest
@testable import InFocusPortal

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

final class CommunityDeepLinkTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func resolve(_ string: String) -> DeepLinkMatch {
        DeepLink.resolve(URL(string: string)!, portal: portal)
    }

    func testCommunityPagesOpenNatively() {
        XCTAssertEqual(resolve("https://portal.example.edu/ideas"),
                       DeepLinkMatch(tab: .more, route: .community(.ideas(date: nil))))
        XCTAssertEqual(resolve("https://portal.example.edu/ideas?date=2026-10-05"),
                       DeepLinkMatch(tab: .more, route: .community(.ideas(date: "2026-10-05"))))
        XCTAssertEqual(resolve("https://portal.example.edu/ideas?date=soon"),
                       DeepLinkMatch(tab: .more, route: .community(.ideas(date: nil))), "a bad date opens the newest set")
        XCTAssertEqual(resolve("https://portal.example.edu/class-board"),
                       DeepLinkMatch(tab: .more, route: .community(.classBoard)))
        XCTAssertEqual(resolve("https://portal.example.edu/activity"),
                       DeepLinkMatch(tab: .more, route: .more(.settings)), "the web redirects /activity to Settings")
        XCTAssertEqual(resolve("https://portal.example.edu/submit-announcement"),
                       DeepLinkMatch(tab: .more, route: .announcements(.submit)))
    }

    func testOtherPathsFallThrough() {
        XCTAssertNil(CommunityRoute.deepLink(["ideas", "extra"], []))
        XCTAssertNil(CommunityRoute.deepLink(["class-board", "x"], []))
        XCTAssertNil(AnnouncementsRoute.deepLink(["submit-announcement", "x"], []))
    }

    func testIdeasPaths() {
        XCTAssertEqual(IdeasPage.path(date: nil), "ideas")
        XCTAssertEqual(IdeasPage.path(date: "2026-10-05"), "ideas?date=2026-10-05")
        XCTAssertEqual(IdeasPage.path(date: "../x"), "ideas")
    }

    func testCatalogLinksResolveToNativeScreens() {
        let config = AppConfig(info: ["InFocusPortalURL": "https://portal.example.edu"])
        let links = PortalPagesCatalog.sections(for: .stub("student"), config: config).flatMap(\.links)
        let routes = Dictionary(uniqueKeysWithValues: links.map { ($0.title, DeepLink.resolve($0.url, portal: portal).route) })
        XCTAssertEqual(routes["Ideas"], .community(.ideas(date: nil)))
        XCTAssertEqual(routes["Class Board"], .community(.classBoard))
        XCTAssertEqual(routes["Submit an announcement"], .announcements(.submit))
    }
}

final class CommunityModelTests: XCTestCase {
    func testDecodesClassBoardCycle() throws {
        let setting = try decode(ClassBoardCycleSetting.self, """
        {"data":{"cycleNumber":null,"cycles":[{"cycleNumber":1,"focus":"Profiles"},{"cycleNumber":2,"focus":"  "}],
         "canEdit":false}}
        """)
        XCTAssertNil(setting.cycleNumber)
        XCTAssertFalse(setting.canEdit)
        XCTAssertEqual(setting.cycles.map(\.label), ["Cycle 1 · Profiles", "Cycle 2"])
        let pinned = try decode(ClassBoardCycleSetting.self, #"{"data":{"cycleNumber":2,"cycles":[],"canEdit":true}}"#)
        XCTAssertEqual(pinned.cycleNumber, 2)
        XCTAssertEqual(try decode(ClassBoardCycleSaved.self, #"{"data":{"cycleNumber":null}}"#).cycleNumber, nil)
        XCTAssertEqual(try decode(ClassBoardCycleSaved.self, #"{"data":{"cycleNumber":3}}"#).cycleNumber, 3)
    }

    func testDecodesPin() throws {
        let pin = try decode(ClassBoardPin.self, #"{"data":{"pin":"123456"}}"#)
        XCTAssertEqual(pin.display, "123 456")
        XCTAssertEqual(try decode(ClassBoardPin.self, #"{"data":{"pin":null}}"#).display, "Not set")
    }

    func testCycleBodySendsNullToFollowTheCurrentCycle() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = PortalClient(portal: URL(string: "https://portal.example.edu")!,
                                  session: URLSession(configuration: config), cookies: { [] })
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"cycleNumber":null}}"#.utf8)) }
        defer { StubProtocol.handler = nil }
        let saved = try await CommunityAPI.live(client).setClassBoardCycle(nil)
        XCTAssertNil(saved.cycleNumber)
        let body = try XCTUnwrap(StubProtocol.lastRequest?.httpBody)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"cycleNumber":null}"#)
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/platform/class-board-cycle")
    }

    func testSavedNotices() {
        XCTAssertEqual(ClassBoardSettingsModel.savedNotice(3), "Class Board shows Cycle 3.")
        XCTAssertEqual(ClassBoardSettingsModel.savedNotice(nil), "Class Board follows the current cycle.")
    }
}

@MainActor
final class ClassBoardSettingsModelTests: XCTestCase {
    func testLoadHidesPinWhenRefusedAndSavesCycle() async {
        var api = CommunityAPI.stub
        api.classBoardPin = { throw PortalError.forbidden("Forbidden") }
        api.setClassBoardCycle = { ClassBoardCycleSaved(cycleNumber: $0) }
        let model = ClassBoardSettingsModel()
        await model.load(api: api)
        XCTAssertNil(model.pin)
        XCTAssertEqual(model.cycle.value?.cycles.count, 2)
        let saved = await model.setCycle(2, api: api)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.cycle.value?.cycleNumber, 2)
        XCTAssertEqual(model.notice, "Class Board shows Cycle 2.")
    }

    func testReadOnlyCycleIsNotSaved() async {
        var api = CommunityAPI.stub
        api.classBoardCycle = { ClassBoardCycleSetting(cycleNumber: nil, cycles: [], canEdit: false) }
        let model = ClassBoardSettingsModel()
        await model.load(api: api)
        let saved = await model.setCycle(1, api: api)
        XCTAssertFalse(saved)
    }

    func testRenewPinShowsTheNewPin() async {
        var api = CommunityAPI.stub
        api.newClassBoardPin = { ClassBoardPin(pin: "654321") }
        let model = ClassBoardSettingsModel()
        let renewed = await model.renewPin(api: api)
        XCTAssertTrue(renewed)
        XCTAssertEqual(model.pin?.display, "654 321")
    }
}

final class AnnouncementFormTests: XCTestCase {
    private func filled() -> AnnouncementForm.Draft {
        var draft = AnnouncementForm.Draft()
        draft.email = " abby@example.edu "
        draft.name = "Abby Example"
        draft.submitterKind = .palyStudent
        draft.runOn = .both
        draft.announcement = "  Robotics Club meets in room 101 at lunch.  "
        draft.startDate = day(2026, 10, 5)
        draft.endDate = day(2026, 10, 7)
        draft.policyAgreed = true
        return draft
    }

    func testBuildsTheWebBody() throws {
        let body = try XCTUnwrap(AnnouncementForm.submission(filled()))
        XCTAssertEqual(body.email, "abby@example.edu")
        XCTAssertEqual(body.announcement, "Robotics Club meets in room 101 at lunch.")
        XCTAssertEqual(body.startDate, "2026-10-05")
        XCTAssertEqual(body.endDate, "2026-10-07")
        let json = try JSONSerialization.jsonObject(with: PortalJSON.encoder().encode(body)) as? [String: Any]
        XCTAssertEqual(json?["submitterKind"] as? String, "PALY_STUDENT")
        XCTAssertEqual(json?["runOn"] as? String, "BOTH")
        XCTAssertEqual(json?["policyAgreed"] as? Bool, true)
        XCTAssertEqual(json?["mediaLink"] as? String, "")
        XCTAssertEqual(Set(json?.keys ?? [:].keys), ["email", "name", "submitterKind", "runOn", "announcement",
                                                    "startDate", "endDate", "policyAgreed", "mediaLink", "moreInfo"])
    }

    func testProblemsInTheWebsWords() {
        var draft = filled()
        draft.email = "abby"
        XCTAssertEqual(AnnouncementForm.problem(draft), "Enter a valid email.")
        draft = filled()
        draft.endDate = day(2026, 10, 1)
        XCTAssertEqual(AnnouncementForm.problem(draft), "End date cannot be before the start date.")
        draft = filled()
        draft.mediaLink = "drive folder"
        XCTAssertEqual(AnnouncementForm.problem(draft), "Media link must be a full URL.")
        draft = filled()
        draft.announcement = String(repeating: "a", count: 4001)
        XCTAssertNotNil(AnnouncementForm.problem(draft))
        draft = filled()
        draft.policyAgreed = false
        XCTAssertEqual(AnnouncementForm.problem(draft), "You must agree to the InFocus announcement policy.")
        XCTAssertNil(AnnouncementForm.submission(draft))
        draft = filled()
        draft.runOn = nil
        XCTAssertEqual(AnnouncementForm.problem(draft), "Choose where this should run.")
    }

    func testSubmitAnotherKeepsDetailsAndDates() {
        let next = AnnouncementForm.another(after: filled())
        XCTAssertEqual(next.email, " abby@example.edu ")
        XCTAssertEqual(next.startDate, day(2026, 10, 5))
        XCTAssertEqual(next.announcement, "")
        XCTAssertFalse(next.policyAgreed)
    }

    func testMovingStartPastEndMovesEnd() {
        let moved = AnnouncementForm.movingStart(filled(), to: day(2026, 10, 9))
        XCTAssertEqual(AnnouncementForm.dateKey(moved.endDate!), "2026-10-09")
        let kept = AnnouncementForm.movingStart(filled(), to: day(2026, 10, 6))
        XCTAssertEqual(AnnouncementForm.dateKey(kept.endDate!), "2026-10-07")
    }

    func testDecodesReceipt() throws {
        let receipt = try decode(AnnouncementReceipt.self, """
        {"data":{"id":"native:abc","announcement":"Hi","email":"abby@example.edu","name":"Abby Example"}}
        """)
        XCTAssertEqual(receipt.id, "native:abc")
    }
}

final class SlackFilesTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    func testFileIDs() {
        XCTAssertTrue(SlackFiles.isFileID("F01EXAMPLE"))
        XCTAssertFalse(SlackFiles.isFileID("../etc"))
        XCTAssertFalse(SlackFiles.isFileID("f01"))
    }

    func testFilenames() {
        XCTAssertEqual(SlackFiles.filename(suggested: "rubric.pdf", title: "Rubric", mimeType: "application/pdf"), "rubric.pdf")
        XCTAssertEqual(SlackFiles.filename(suggested: "F01EXAMPLE", title: "Initial Cut rubric", mimeType: "application/pdf"),
                       "Initial Cut rubric.pdf")
        XCTAssertEqual(SlackFiles.filename(suggested: nil, title: "../../notes", mimeType: "text/plain"), "notes.txt")
        XCTAssertEqual(SlackFiles.filename(suggested: nil, title: "", mimeType: nil), "Attachment")
    }

    func testDownloadsThroughTheProxyToALocalFile() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let client = PortalClient(portal: URL(string: "https://portal.example.edu")!, session: session, cookies: { [] })
        StubProtocol.handler = { _ in (200, Data("hello".utf8)) }
        let url = try await SlackFiles.download(id: "F01EXAMPLE", title: "Rubric", client: client, session: session)
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/slack/files/F01EXAMPLE")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testDownloadErrorsUseThePortalsWords() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let client = PortalClient(portal: URL(string: "https://portal.example.edu")!, session: session, cookies: { [] })
        StubProtocol.handler = { _ in (413, Data(#"{"error":{"message":"That file is too large to open here."}}"#.utf8)) }
        do {
            _ = try await SlackFiles.download(id: "F01EXAMPLE", title: "Big", client: client, session: session)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PortalError, .server(status: 413, message: "That file is too large to open here."))
        }
    }
}
