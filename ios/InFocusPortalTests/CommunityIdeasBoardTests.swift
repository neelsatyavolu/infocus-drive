import XCTest
@testable import InFocusPortal

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
}

private func stubClient() -> PortalClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return PortalClient(portal: URL(string: "https://portal.example.edu")!,
                        session: URLSession(configuration: config), cookies: { [] })
}

private let ideasJSON = """
{"data":{"batch":{"runDate":"2026-10-03","itemCount":30,"ideas":[
 {"title":"Bike lane","pitch":"A new lane.","angle":"Riders.","category":"feature",
  "sources":[{"title":"Lane story","outlet":"Example News","url":"https://example.com/a"},
             {"title":"Bad link","outlet":"Example","url":"javascript:alert(1)"}]},
 {"title":"Budget vote","pitch":"The board votes.","angle":"Ask students.","category":"news","sources":[]},
 {"title":"Mystery","pitch":"?","angle":"?","category":"poetry","sources":[]},
 {"title":"Finals","pitch":"Moved.","angle":"Both sides.","category":"news","sources":[]}
]},"runDates":["2026-10-05","2026-10-03","2026-09-29"]}}
"""

final class IdeasTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    func testDecodesIdeasAndGroupsSections() throws {
        let payload = try decode(IdeasPayload.self, ideasJSON)
        let batch = try XCTUnwrap(payload.batch)
        XCTAssertEqual(batch.itemCount, 30)
        XCTAssertEqual(batch.sections.map(\.category), [.news, .feature], "web order, unknown and empty categories left out")
        XCTAssertEqual(batch.sections[0].items.map(\.idea.title), ["Budget vote", "Finals"])
        XCTAssertEqual(Set(batch.sections.flatMap(\.items).map(\.id)).count, 3)
        XCTAssertEqual(batch.summary, "4 ideas from 30 local stories · New every 2 days")
        let sources = batch.ideas[0].sources
        XCTAssertEqual(sources[0].link?.absoluteString, "https://example.com/a")
        XCTAssertNil(sources[1].link, "only web links open")
    }

    func testLatestAndNeighbors() throws {
        let past = try decode(IdeasPayload.self, ideasJSON)
        XCTAssertFalse(past.isLatest)
        XCTAssertEqual(past.olderDate, "2026-09-29")
        XCTAssertEqual(past.newerDate, "2026-10-05")
        let none = try decode(IdeasPayload.self, #"{"data":{"batch":null,"runDates":[]}}"#)
        XCTAssertNil(none.batch)
        XCTAssertFalse(none.isLatest)
        XCTAssertNil(none.olderDate)
        let latest = CommunityStubs.ideas(date: nil)
        XCTAssertTrue(latest.isLatest)
        XCTAssertNil(latest.newerDate)
    }

    func testRunDateFormats() {
        XCTAssertEqual(IdeasFormat.runDate("2026-10-05", .long), "Monday, October 5")
        XCTAssertEqual(IdeasFormat.runDate("2026-10-05", .short), "Mon, Oct 5")
        XCTAssertEqual(IdeasFormat.runDate("bad", .short), "bad")
        let groups = IdeasFormat.monthGroups(["2026-10-05", "2026-10-03", "2026-09-29"])
        XCTAssertEqual(groups.map(\.month), ["October 2026", "September 2026"])
        XCTAssertEqual(groups.map(\.runDates), [["2026-10-05", "2026-10-03"], ["2026-09-29"]])
    }

    func testEmptyStatesInTheWebsWords() throws {
        let none = IdeasPayload(batch: nil, runDates: ["2026-10-05"])
        XCTAssertEqual(IdeasModel.emptyState(none, requested: "2026-01-01")?.title, "No ideas for that date")
        XCTAssertEqual(IdeasModel.emptyState(none, requested: "2026-01-01")?.showLatest, true)
        XCTAssertEqual(IdeasModel.emptyState(IdeasPayload(batch: nil, runDates: []), requested: nil)?.title, "No ideas yet")
        let unknown = IdeasPayload(batch: IdeaBatch(runDate: "2026-10-05", itemCount: 1, ideas: [
            Idea(title: "x", pitch: "", angle: "", category: "poetry", sources: [])
        ]), runDates: ["2026-10-05"])
        XCTAssertEqual(IdeasModel.emptyState(unknown, requested: nil)?.title, "These ideas could not be shown")
        XCTAssertNil(IdeasModel.emptyState(try decode(IdeasPayload.self, ideasJSON), requested: nil))
    }

    func testLiveCallSendsTheDateOnlyWhenValid() async throws {
        let client = stubClient()
        StubProtocol.handler = { _ in (200, Data(ideasJSON.utf8)) }
        _ = try await CommunityAPI.live(client).ideas("2026-10-03")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/ideas")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.query, "date=2026-10-03")
        _ = try await CommunityAPI.live(client).ideas("../x")
        XCTAssertNil(StubProtocol.lastRequest?.url?.query)
    }
}

@MainActor
final class IdeasModelTests: XCTestCase {
    func testShowingTheNewestSetAsksWithoutADate() async {
        var api = CommunityAPI.stub
        let asked = AskedDates()
        api.ideas = { date in
            await asked.append(date)
            return CommunityStubs.ideas(date: date)
        }
        let model = IdeasModel(date: "2026-10-03")
        await model.load(api: api)
        XCTAssertEqual(model.state.value?.batch?.runDate, "2026-10-03")
        await model.show("2026-10-05", api: api)
        XCTAssertNil(model.requested)
        await model.show("2026-09-29", api: api)
        XCTAssertEqual(model.state.value?.batch?.runDate, "2026-09-29")
        let dates = await asked.dates
        XCTAssertEqual(dates, ["2026-10-03", nil, "2026-09-29"])
    }

    func testFailureShowsTheError() async {
        var api = CommunityAPI.stub
        api.ideas = { _ in throw PortalError.server(status: 400, message: "date must be YYYY-MM-DD") }
        let model = IdeasModel(date: nil)
        await model.load(api: api)
        guard case .failed(let message) = model.state else { return XCTFail("expected a failure") }
        XCTAssertFalse(message.isEmpty)
    }
}

private actor AskedDates {
    var dates: [String?] = []
    func append(_ date: String?) { dates.append(date) }
}

private let boardJSON = """
{"data":{"classSessions":[{"date":"2026-10-15","startsAt":"2026-10-15T15:30:00.000Z","endsAt":"2026-10-15T16:30:00.000Z"}],
"deadlines":[{"id":"3-finalCut","cycleNumber":3,"label":"Final Cut","dateKey":"2026-10-17","daysUntil":2,"when":"in 2d",
  "focus":"Finish your Final Cut"}],
"generatedAt":"2026-10-15T15:42:00.000Z","cycleNumber":3,"cycleFocus":"Sports",
"gates":[{"key":"pitching","label":"Pitching","dateLabel":"Sep 30"},{"key":"final-cut","label":"Final Cut","dateLabel":null}],
"lanes":[{"id":"r1","place":1,"topic":"Robotics","detail":"Abby · Otto · AP Sage","extension":true,"extensionDays":10,
  "statusLabel":"V2 Needs Revisions","tone":"warn","packageOfCycle":false,"doneCount":1,"dots":["done","current"],
  "segments":["done","current"]}],
"livestreams":[{"id":"l1","dateKey":"2026-10-16","dayLabel":"Fri, Oct 16","timeLabel":"6:00 PM","started":false,
  "title":"Fall concert","where":"Theater","crew":"Crew open","openLabel":"3 open","tone":"open","availability":"Public"}],
"days":[{"date":"2026-10-15","weekday":"THU","dayNum":"15","kind":"SHOW","kindLabel":"Show",
  "lines":["Anchors  Abby · Otto","Spirit day  fun"]},
  {"date":"2026-10-16","weekday":"FRI","dayNum":"16","kind":"HOLIDAY","kindLabel":"Teacher work day","lines":[]}]}}
"""

final class ClassBoardTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    func testDecodesTheBoard() throws {
        let board = try decode(ClassBoard.self, boardJSON)
        XCTAssertEqual(board.cycleNumber, 3)
        XCTAssertEqual(board.gates.map(\.dateLabel), ["Sep 30", nil])
        XCTAssertEqual(board.lanes.first?.extensionDays, 10)
        XCTAssertEqual(board.lanes.first?.dots, ["done", "current"])
        XCTAssertEqual(board.livestreams.first?.where, "Theater")
        XCTAssertTrue(board.days[1].isHoliday)
        XCTAssertEqual(board.classSessions.first?.endsAt, PortalJSON.date(from: "2026-10-15T16:30:00Z"))
    }

    func testLiveCallPath() async throws {
        StubProtocol.handler = { _ in (200, Data(boardJSON.utf8)) }
        _ = try await CommunityAPI.live(stubClient()).classBoard()
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/class-board")
    }

    func testTagsAndLabels() {
        XCTAssertEqual(ClassBoardFormat.relativeDays(0), "Today")
        XCTAssertEqual(ClassBoardFormat.relativeDays(8), "in 8d")
        XCTAssertEqual(ClassBoardFormat.dueTone(1), .warning)
        XCTAssertEqual(ClassBoardFormat.dueTone(2), .neutral)
        XCTAssertEqual(ClassBoardFormat.laneTone("approved"), .success)
        XCTAssertEqual(ClassBoardFormat.laneTone("review"), .neutral)
        XCTAssertEqual(ClassBoardFormat.laneTone("something-new"), .neutral)
        XCTAssertEqual(ClassBoardFormat.capacityTone("full"), .neutral)
        XCTAssertEqual(ClassBoardFormat.capacityTone("one"), .warning)
        XCTAssertEqual(ClassBoardFormat.extensionLabel(10), "10 Day Extension")
        XCTAssertEqual(ClassBoardFormat.extensionLabel(0), "Extension")
        XCTAssertEqual(ClassBoardFormat.gateShortLabel(.init(key: "initial-stage-2", label: "Initial Cut 2", dateLabel: nil)), "Init 2")
        XCTAssertEqual(ClassBoardFormat.gateShortLabel(.init(key: "new", label: "New gate", dateLabel: nil)), "New gate")
        XCTAssertEqual(ClassBoardFormat.shortDate("2026-10-17"), "Oct 17")
        XCTAssertEqual(ClassBoardFormat.weekdayAndDay("2026-10-15").weekday, "THU")
    }

    func testDayTagsAndRoleLines() throws {
        let board = try decode(ClassBoard.self, boardJSON)
        XCTAssertEqual(ClassBoardFormat.dayTag(board.days[0]).label, "Show")
        XCTAssertEqual(ClassBoardFormat.dayTag(board.days[0]).tone, .success)
        let holiday = ClassBoardFormat.dayTag(board.days[1])
        XCTAssertEqual(holiday.label, "No school")
        XCTAssertEqual(ClassBoardFormat.dayLines(board.days[1]), ["Teacher work day"])
        let anchors = ClassBoardFormat.splitRoleLine("Anchors  Abby · Otto")
        XCTAssertEqual(anchors.role, "Anchors")
        XCTAssertEqual(anchors.value, "Abby · Otto")
        XCTAssertNil(ClassBoardFormat.splitRoleLine("Spirit day  fun").role, "only known roles split")
    }

    func testFocusDuringClassAndOutside() throws {
        let board = try decode(ClassBoard.self, boardJSON)
        let inClass = try XCTUnwrap(ClassBoardFormat.focus(board, now: try XCTUnwrap(PortalJSON.date(from: "2026-10-15T16:25:00Z"))))
        XCTAssertEqual(inClass.eyebrow, "Class focus")
        XCTAssertEqual(inClass.text, "Finish your Final Cut")
        XCTAssertEqual(inClass.detail, "Cycle 3 · Due in 2d")
        XCTAssertEqual(inClass.countdown, "5:00")
        XCTAssertTrue(inClass.ending)
        let after = try XCTUnwrap(ClassBoardFormat.focus(board, now: try XCTUnwrap(PortalJSON.date(from: "2026-10-15T20:00:00Z"))))
        XCTAssertEqual(after.eyebrow, "Up next")
        XCTAssertNil(after.countdown)
        XCTAssertEqual(after.tag, "in 2d")
        XCTAssertEqual(after.detail, "Final Cut · Cycle 3")
    }
}

@MainActor
final class ClassBoardModelTests: XCTestCase {
    func testKeepsTheBoardWhenARefreshFails() async {
        var api = CommunityAPI.stub
        let model = ClassBoardModel()
        await model.load(api: api)
        XCTAssertNotNil(model.state.value)
        XCTAssertFalse(model.stale)
        api.classBoard = { throw PortalError.offline }
        await model.load(api: api)
        XCTAssertNotNil(model.state.value)
        XCTAssertTrue(model.stale)
    }

    func testFirstFailureShowsTheError() async {
        var api = CommunityAPI.stub
        api.classBoard = { throw PortalError.offline }
        let model = ClassBoardModel()
        await model.load(api: api)
        guard case .failed = model.state else { return XCTFail("expected a failure") }
    }
}
