import XCTest
@testable import InFocusPortal

private let pacific: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    pacific.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

final class HarvestSeasonDateTests: XCTestCase {
    func testNovemberInLocalTimeIsTheSeason() {
        XCTAssertFalse(HarvestSeason.isSeason(local(2026, 10, 31, 23, 59, 59), calendar: pacific))
        XCTAssertTrue(HarvestSeason.isSeason(local(2026, 11, 1), calendar: pacific))
        XCTAssertTrue(HarvestSeason.isSeason(local(2026, 11, 26, 12), calendar: pacific))
        XCTAssertTrue(HarvestSeason.isSeason(local(2026, 11, 30, 23, 59, 59), calendar: pacific))
        XCTAssertFalse(HarvestSeason.isSeason(local(2026, 12, 1), calendar: pacific))
    }

    func testSeasonFollowsTheLocalClockNotUTC() {
        // 5 PM on October 31 in California is already November 1 in UTC.
        let evening = local(2026, 10, 31, 17)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertFalse(HarvestSeason.isSeason(evening, calendar: pacific))
        XCTAssertTrue(HarvestSeason.isSeason(evening, calendar: utc))
    }

    func testTurnedOffOnThisDeviceIsOff() {
        XCTAssertTrue(HarvestSeason.isOn(off: false, now: local(2026, 11, 4), calendar: pacific))
        XCTAssertFalse(HarvestSeason.isOn(off: true, now: local(2026, 11, 4), calendar: pacific))
        XCTAssertFalse(HarvestSeason.isOn(off: false, now: local(2026, 12, 4), calendar: pacific))
    }

    func testWelcomeOncePerYear() {
        let now = local(2026, 11, 2)
        XCTAssertTrue(HarvestSeason.needsWelcome(stored: nil, now: now, calendar: pacific))
        XCTAssertTrue(HarvestSeason.needsWelcome(stored: "2025", now: now, calendar: pacific))
        XCTAssertFalse(HarvestSeason.needsWelcome(stored: "2026", now: now, calendar: pacific))
    }

    func testNextMidnight() {
        XCTAssertEqual(HarvestSeason.nextMidnight(after: local(2026, 10, 31, 22, 15), calendar: pacific), local(2026, 11, 1))
    }
}

@MainActor
final class HarvestSeasonStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var now = Date()

    override func setUp() {
        defaults = UserDefaults(suiteName: "HarvestSeasonStoreTests")!
        defaults.removePersistentDomain(forName: "HarvestSeasonStoreTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "HarvestSeasonStoreTests")
        HarvestSeasonStore.shared.refresh() // put the app's palette back
    }

    private func store() -> HarvestSeasonStore {
        HarvestSeasonStore(defaults: defaults, calendar: pacific, clock: { [unowned self] in now }, forced: nil)
    }

    func testOnInNovemberAndTheBrandPaletteFollows() {
        now = local(2026, 11, 1)
        let season = store()
        XCTAssertTrue(season.isOn)
        XCTAssertTrue(HarvestPalette.isActive)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertEqual(Brand.uiFill.resolvedColor(with: dark), UIColor(hex: 0xA4471C))
        XCTAssertEqual(Brand.uiGreen.resolvedColor(with: dark), UIColor(hex: 0xF2A93B))
        XCTAssertEqual(Brand.uiGreen.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)), UIColor(hex: 0x9A4A10))

        season.themeOff = true
        XCTAssertFalse(season.isOn)
        XCTAssertTrue(season.isSeason) // the toggles still show
        XCTAssertFalse(HarvestPalette.isActive)
        XCTAssertEqual(Brand.uiFill.resolvedColor(with: dark), UIColor(hex: 0x0B6E3E))
        XCTAssertTrue(store().themeOff, "kept on this device")
    }

    func testOffAfterNovemberOnRefresh() {
        now = local(2026, 11, 30, 23, 59)
        let season = store()
        XCTAssertTrue(season.isOn)
        now = local(2026, 12, 1)
        season.refresh()
        XCTAssertFalse(season.isOn)
        XCTAssertFalse(season.isSeason)
    }

    func testWelcomeShowsOnceAYear() {
        now = local(2026, 11, 3)
        let season = store()
        XCTAssertTrue(season.needsWelcome)
        season.markWelcomed()
        XCTAssertFalse(season.needsWelcome)
        XCTAssertFalse(store().needsWelcome, "remembered on this device")
        now = local(2027, 11, 1)
        season.refresh()
        XCTAssertTrue(season.needsWelcome)
    }

    func testNoWelcomeWhileTheThemeIsOff() {
        now = local(2026, 11, 3)
        let season = store()
        season.themeOff = true
        XCTAssertFalse(season.needsWelcome)
    }

    func testCountsAreKept() {
        now = local(2026, 11, 3)
        let season = store()
        XCTAssertEqual(season.countLeaf(), 1)
        XCTAssertEqual(season.countLeaf(), 2)
        XCTAssertEqual(season.countPie(), 1)
        XCTAssertEqual(store().leaves, 2)
    }
}

final class HarvestBoardTests: XCTestCase {
    private let json = """
    {"data":{"year":2026,
      "rows":[
        {"userId":"u1","name":"Sage","leaves":30,"pies":5,"wishbones":1,"giantTurkeys":1,"pardons":3,"total":40,"rank":1},
        {"userId":"u2","name":"Abby","leaves":20,"pies":8,"wishbones":0,"giantTurkeys":0,"pardons":2,"total":30,"rank":2},
        {"userId":"u3","name":"Otto","leaves":22,"pies":6,"wishbones":0,"giantTurkeys":0,"pardons":2,"total":30,"rank":2},
        {"userId":"u4","name":"Sage B","leaves":9,"pies":0,"wishbones":0,"giantTurkeys":0,"pardons":0,"total":9,"rank":4}
      ],
      "disqualified":[{"userId":"u5","name":"Otto B","leaves":400,"pies":0,"wishbones":0,"giantTurkeys":0,"pardons":0,"total":400}],
      "viewerId":"u3",
      "contest":{"closesAt":"2026-11-06T07:59:59.999Z","prizeDays":2,"result":null},
      "review":null}}
    """

    private func board(_ text: String? = nil) throws -> HarvestBoard {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<HarvestBoard>.self, from: Data((text ?? json).utf8)).data
    }

    func testDecodesRanksTiesAndTheViewer() throws {
        let board = try board()
        XCTAssertEqual(board.rows.map(\.rank), [1, 2, 2, 4], "ties share a rank")
        XCTAssertEqual(board.rows.map(\.name), ["Sage", "Abby", "Otto", "Sage B"])
        XCTAssertEqual(board.rows.filter(board.isViewer).map(\.name), ["Otto"])
        XCTAssertFalse(board.viewerDisqualified)
        XCTAssertEqual(board.disqualified.first?.rank, nil)
        XCTAssertEqual(board.disqualified.first?.total, 400)
        XCTAssertEqual(board.rows[0].count(.giantTurkeys), 1)
        XCTAssertEqual(board.contest?.prizeDays, 2)
        XCTAssertNil(board.contest?.result)
    }

    func testViewerDisqualified() throws {
        let board = try board(json.replacingOccurrences(of: #""viewerId":"u3""#, with: #""viewerId":"u5""#))
        XCTAssertTrue(board.viewerDisqualified)
    }

    func testWebLabelsInOrder() {
        XCTAssertEqual(HarvestKind.allCases.map(\.label), ["Leaves", "Pies", "Wishbones", "Giant turkeys", "Pardons"])
    }

    func testContestBannerBeforeAndAfterTheClose() throws {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let closes = try board().contest!
        XCTAssertEqual(ContestBannerText.closesLabel(closes.closesAt, timeZone: la), "11:59 PM Thu, Nov 5")

        let open = ContestBannerText(contest: closes, viewerId: "u3", now: local(2026, 11, 4), timeZone: la)
        XCTAssertEqual(open.headline, "2 FREE EXTENSION DAYS")
        XCTAssertTrue(open.detail.hasPrefix("Whoever is #1 on the leaderboard at 11:59 PM Thu, Nov 5 wins 2 extension days"))

        let after = local(2026, 11, 7)
        let winners = HarvestBoard.Contest(closesAt: closes.closesAt, prizeDays: 2, result: .init(
            winners: [.init(userId: "u1", name: "Sage"), .init(userId: "u2", name: "Abby")], total: 40, ungranted: ["u2"]))
        let someoneElse = ContestBannerText(contest: winners, viewerId: "u3", now: after, timeZone: la)
        XCTAssertEqual(someoneElse.headline, "SAGE AND ABBY WON")
        XCTAssertTrue(someoneElse.detail.hasPrefix("2 free extension days for their package group, #1 at 11:59 PM Thu, Nov 5 with 40."))

        let mine = ContestBannerText(contest: winners, viewerId: "u2", now: after, timeZone: la)
        XCTAssertEqual(mine.headline, "YOU WON 2 FREE EXTENSION DAYS")
        XCTAssertTrue(mine.detail.contains("an exec will add the days by hand"))

        let none = ContestBannerText(contest: closes, viewerId: "u3", now: after, timeZone: la)
        XCTAssertEqual(none.headline, "THE CONTEST IS OVER")
    }

    func testJoinNames() {
        XCTAssertEqual(ContestBannerText.joinNames(["Abby"]), "Abby")
        XCTAssertEqual(ContestBannerText.joinNames(["Abby", "Otto", "Sage"]), "Abby, Otto and Sage")
    }

    func testDeepLinkOpensTheLeaderboardOnMore() {
        let portal = URL(string: "https://portal.example.edu")!
        let match = DeepLink.resolve(URL(string: "https://portal.example.edu/thanksgiving")!, portal: portal)
        XCTAssertEqual(match, DeepLinkMatch(tab: .more, route: .seasonal(.leaderboard)))
    }
}

/// Every POST the stub saw, read on the test's thread.
private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    var replies: [Int] = []

    func record(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        bodies.append(body)
        return replies.isEmpty ? 200 : replies.removeFirst()
    }

    var all: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }

    func catches(_ index: Int) -> [[String: Any]] { all[index]["catches"] as? [[String: Any]] ?? [] }
}

@MainActor
final class HarvestTallyTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!
    private var now = Date(timeIntervalSince1970: 1_793_000_000)
    private let requests = Requests()

    override func setUp() {
        SampleMode.set(false)
        let requests = requests
        StubProtocol.handler = { request in
            let status = requests.record(request)
            return (status, Data(#"{"data":{"accepted":1,"rejected":0}}"#.utf8))
        }
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    private func tally() -> HarvestTally {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = PortalClient(portal: portal, session: URLSession(configuration: config), cookies: { [] })
        let api = HarvestAPI.live(client)
        return HarvestTally(send: api.send, clock: { [unowned self] in now }, delay: 3_600)
    }

    private func advance(_ ms: Double) { now = now.addingTimeInterval(ms / 1000) }

    func testBatchEncodingMatchesThePortalSchema() throws {
        let batch = HarvestBatch(catches: [HarvestCatch(kind: .leaves, at: 1_793_000_000_500, age: 4_200),
                                           HarvestCatch(kind: .giantTurkeys, at: 1_793_000_001_000, age: nil)],
                                 sentAt: 1_793_000_002_000)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: PortalJSON.encoder().encode(batch)) as? [String: Any])
        XCTAssertEqual(json["sentAt"] as? Int64, 1_793_000_002_000)
        XCTAssertEqual(json["automation"] as? Bool, false)
        let catches = try XCTUnwrap(json["catches"] as? [[String: Any]])
        XCTAssertEqual(catches[0]["kind"] as? String, "leaves")
        XCTAssertEqual(catches[0]["at"] as? Int64, 1_793_000_000_500)
        XCTAssertEqual(catches[0]["age"] as? Int64, 4_200)
        XCTAssertEqual(catches[1]["kind"] as? String, "giantTurkeys")
        XCTAssertTrue(catches[1].keys.contains("age"), "the Portal requires age, null for giant turkeys")
        XCTAssertTrue(catches[1]["age"] is NSNull)
    }

    func testSendsCatchesWithTheirTimesAndAges() async {
        let tally = tally()
        let born = now
        advance(1_500)
        XCTAssertTrue(tally.tap(.leaves, bornAt: born))
        advance(400)
        XCTAssertTrue(tally.tap(.pies, bornAt: born))
        tally.giantTurkey()
        await tally.flush()

        XCTAssertEqual(requests.all.count, 1)
        let catches = requests.catches(0)
        XCTAssertEqual(catches.map { $0["kind"] as? String }, ["leaves", "pies", "giantTurkeys"])
        XCTAssertEqual(catches.map { $0["age"] as? Int64 }, [1_500, 1_900, nil])
        XCTAssertEqual(catches[0]["at"] as? Int64, HarvestTally.ms(born) + 1_500)
        XCTAssertEqual(requests.all[0]["automation"] as? Bool, false)
        XCTAssertEqual(requests.all[0]["sentAt"] as? Int64, HarvestTally.ms(now))
        XCTAssertTrue(tally.pending.isEmpty)
    }

    func testFailedSendKeepsTheSameCatchesAndSendsThemOnce() async {
        requests.replies = [503, 200]
        let tally = tally()
        let born = now
        advance(2_000)
        tally.tap(.leaves, bornAt: born)
        await tally.flush()
        XCTAssertEqual(tally.pending.count, 1, "kept after the Portal was busy")

        advance(300)
        tally.tap(.leaves, bornAt: born)
        advance(10_000)
        await tally.flush()

        XCTAssertEqual(requests.all.count, 2)
        // The retry carries the first catch exactly as before (so a re-send is spotted), then the new one.
        XCTAssertEqual(requests.catches(1).first?["at"] as? Int64, requests.catches(0).first?["at"] as? Int64)
        XCTAssertEqual(requests.catches(1).first?["age"] as? Int64, 2_000)
        XCTAssertEqual(requests.catches(1).count, 2)
        XCTAssertTrue(tally.pending.isEmpty)

        await tally.flush()
        XCTAssertEqual(requests.all.count, 2, "nothing sent twice once saved")
    }

    func testOfflineIsRetriedButARefusalIsDropped() async {
        XCTAssertTrue(HarvestTally.isRetryable(PortalError.offline))
        XCTAssertTrue(HarvestTally.isRetryable(PortalError.server(status: 429, message: "")))
        XCTAssertFalse(HarvestTally.isRetryable(PortalError.forbidden("No")))

        requests.replies = [400]
        let tally = tally()
        let born = now
        advance(1_000)
        tally.tap(.pies, bornAt: born)
        await tally.flush()
        XCTAssertTrue(tally.pending.isEmpty, "the Portal refused it; sending it again won't help")
    }

    func testOverlappingFlushesSendEachCatchOnce() async {
        let tally = tally()
        let born = now
        advance(1_000)
        tally.tap(.leaves, bornAt: born)
        async let first: Void = tally.flush()
        async let second: Void = tally.flush()
        _ = await (first, second)
        let sent = requests.all.flatMap { ($0["catches"] as? [[String: Any]]) ?? [] }
        XCTAssertEqual(sent.count, 1)
    }

    func testTooFastOrTooNewTapsAreNotCounted() {
        let tally = tally()
        let born = now
        advance(100)
        XCTAssertFalse(tally.tap(.leaves, bornAt: born), "a visitor on screen for 100 ms looks like a script")
        advance(900)
        XCTAssertTrue(tally.tap(.leaves, bornAt: born))
        advance(60)
        XCTAssertFalse(tally.tap(.leaves, bornAt: born), "two taps 60 ms apart")
        advance(200)
        XCTAssertTrue(tally.tap(.leaves, bornAt: born))
        advance(500)
        XCTAssertFalse(tally.tap(.pardons, bornAt: now.addingTimeInterval(-0.5)), "a pardon needs the turkey on screen longer")
        XCTAssertEqual(tally.pending.count, 2)
    }

    func testBatchesAreCappedAtTwoHundred() async {
        let tally = tally()
        let born = now
        for _ in 0..<250 {
            advance(300)
            tally.tap(.leaves, bornAt: born)
        }
        await tally.flush()
        XCTAssertEqual(requests.all.count, 2)
        XCTAssertEqual(requests.catches(0).count, 200)
        XCTAssertEqual(requests.catches(1).count, 50)
    }
}

@MainActor
final class HarvestGameTests: XCTestCase {
    func testPickFollowsTheWebWeights() {
        XCTAssertEqual(HarvestGame.pick(0), .leaves)
        XCTAssertEqual(HarvestGame.pick(0.38), .leaves)
        XCTAssertEqual(HarvestGame.pick(0.5), .pie)
        XCTAssertEqual(HarvestGame.pick(0.7), .strut)
        XCTAssertEqual(HarvestGame.pick(0.9), .gust)
        XCTAssertEqual(HarvestGame.pick(0.99), .wishbone)
    }

    func testFiveTapsPardonATurkey() {
        let game = HarvestGame()
        let id = game.spawn(.strut(rightToLeft: false, taps: 0, pardoned: false, lastTap: nil), duration: 14)
        for tap in 1...4 { XCTAssertEqual(game.tapTurkey(id)?.pardoned, false, "tap \(tap)") }
        XCTAssertEqual(game.tapTurkey(id)?.pardoned, true)
        XCTAssertNil(game.tapTurkey(id), "already pardoned")
        game.stop()
    }

    func testReduceMotionOnlyBringsPiesAndAtMostThree() {
        let game = HarvestGame()
        game.reduceMotion = true
        for _ in 0..<5 { game.visit() }
        XCTAssertEqual(game.sprites.count, 3)
        XCTAssertTrue(game.sprites.allSatisfy { if case .pie = $0.kind { true } else { false } })
        game.stop()
    }
}

@MainActor
final class HarvestPlayTests: XCTestCase {
    func testGiantTurkeyCountsWhenItWalksInAndOnlyWhenAllowed() {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let tally = HarvestTally(send: { _ in }, delay: 3_600)
        let play = HarvestPlay(tally: tally, now: start, firstGiantIn: 60)
        play.checkGiant(allowed: true, now: start.addingTimeInterval(30))
        XCTAssertNil(play.giantAt)
        play.checkGiant(allowed: false, now: start.addingTimeInterval(61))
        XCTAssertNil(play.giantAt, "turned off, or Reduce Motion")
        play.checkGiant(allowed: true, now: start.addingTimeInterval(62))
        XCTAssertNotNil(play.giantAt)
        XCTAssertEqual(tally.pending.map(\.kind), [.giantTurkeys])
        XCTAssertNil(tally.pending.first?.age)
        play.checkGiant(allowed: true, now: start.addingTimeInterval(80))
        XCTAssertNil(play.giantAt, "gone after its visit")
        XCTAssertEqual(tally.pending.count, 1, "next one is half an hour away at least")
    }
}
