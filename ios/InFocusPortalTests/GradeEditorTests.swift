import XCTest
@testable import InFocusPortal

/// Decoding the Portal's Grade Editor answers (fictional fixtures).
final class GradeEditorDecodingTests: XCTestCase {
    func testCycleViewDecodesEveryCellKind() throws {
        let grades = try GradeEditorFixtures.cycle(2)
        XCTAssertEqual(grades.activeCycleNumber, 2)
        XCTAssertEqual(grades.activeCycle?.title, "Cycle 2: Features")
        XCTAssertEqual(grades.rows.count, 6)

        let abby = try XCTUnwrap(grades.rows.first { $0.userId == "u-abby" })
        XCTAssertEqual(abby.effortPoints, 46)
        XCTAssertTrue(abby.published)
        XCTAssertEqual(abby.checkInScores?[.initialCut], .points(4))
        XCTAssertEqual(abby.turnedInDate, "2026-10-27")

        let juno = try XCTUnwrap(grades.rows.first { $0.userId == "u-juno" })
        XCTAssertEqual(juno.finalCutState, .exempt)
        XCTAssertEqual(juno.checkInScores?[.pitching], .state(.exempt))

        let kai = try XCTUnwrap(grades.rows.first { $0.userId == "u-kai" })
        XCTAssertNil(kai.checkInScores?[.proofOfContact], "not released yet")

        let sage = try XCTUnwrap(grades.rows.first { $0.userId == "u-sage" })
        XCTAssertEqual(sage.checkInOverrides?[.aRollBRoll], .points(0))
        XCTAssertNil(sage.checkInOverrides?[.pitching])
    }

    func testTotalsKeepNotGradeableAsNil() throws {
        let totals = try GradeEditorFixtures.decode(GradeTotals.self, GradeEditorFixtures.totalsJSON)
        let otto = try XCTUnwrap(totals.totalsRows.first { $0.userId == "u-otto" })
        XCTAssertNil(otto.livestreamPoints)
        XCTAssertEqual(otto.cycleTotals.first { $0.cycleNumber == 2 }?.totalPoints, 38.4)
        XCTAssertEqual(totals.totalsRows.first { $0.userId == "u-juno" }?.cycleTotals.first?.finalCutState, .exempt)
    }

    func testMissingGradebookAndParticipation() throws {
        let missing = try GradeEditorFixtures.decode(MissingGrades.self, GradeEditorFixtures.missingJSON)
        XCTAssertEqual(missing.missingReport.first { $0.userId == "u-kai" }?.missing.map(\.status), [.notEntered, .notEntered])

        let book = try GradeEditorFixtures.gradebook("u-abby")
        XCTAssertEqual(book.estimated.letter, "A-")
        XCTAssertEqual(book.estimated.packages.finalCutPoints, [47, 46])

        let week = try GradeEditorFixtures.participation("2026-10-05")
        XCTAssertEqual(week.gradedDays.map(\.maxPoints), [10, 20, 20])
        XCTAssertEqual(week.pending("u-sage", "2026-10-06")?.points, 15)

        let requests = try GradeEditorFixtures.decode(ParticipationRequests.self, GradeEditorFixtures.requestsJSON)
        XCTAssertTrue(requests.requests.first?.canReview == true)
    }
}

/// The web's rules, mirrored.
final class GradeEditorLogicTests: XCTestCase {
    func testFinalCutParsingMatchesTheWeb() {
        XCTAssertEqual(GradeEditorLogic.parseFinalCut(""), .state(.ungraded))
        XCTAssertEqual(GradeEditorLogic.parseFinalCut(" - "), .state(.ungraded))
        XCTAssertEqual(GradeEditorLogic.parseFinalCut("\\"), .state(.exempt))
        XCTAssertEqual(GradeEditorLogic.parseFinalCut("42"), .points(42))
        XCTAssertEqual(GradeEditorLogic.parseFinalCut("41.6"), .points(42))
        XCTAssertEqual(GradeEditorLogic.parseFinalCut("75"), .points(50), "capped at 50")
        XCTAssertNil(GradeEditorLogic.parseFinalCut("4o"))
        XCTAssertNil(GradeEditorLogic.parseFinalCut("-3"))
    }

    func testFiltersStatusAndPublishAll() throws {
        let rows = try GradeEditorFixtures.cycle(2).rows
        XCTAssertEqual(GradeEditorLogic.rows(rows, filter: .toGrade, search: "").map(\.userId), ["u-rio", "u-kai"])
        XCTAssertEqual(GradeEditorLogic.rows(rows, filter: .unpublished, search: "").map(\.userId), ["u-sage"])
        XCTAssertEqual(GradeEditorLogic.rows(rows, filter: .all, search: "OTTO").map(\.userId), ["u-otto"])
        XCTAssertEqual(GradeEditorLogic.publishable(rows).map(\.userId), ["u-sage"])
        XCTAssertEqual(GradeEditorLogic.status(rows[1]), .revised)
        XCTAssertFalse(GradeEditorLogic.canPublish(rows[3]), "no Final Cut score yet")
    }

    func testCheckInChoices() {
        XCTAssertEqual(GradeEditorLogic.CheckInChoice.all.count, 9)
        XCTAssertNil(GradeEditorLogic.CheckInChoice.automatic.body)
        XCTAssertEqual(GradeEditorLogic.CheckInChoice.points(3).body, .points(3))
        XCTAssertEqual(GradeEditorLogic.choice(override: nil), .automatic)
        XCTAssertEqual(GradeEditorLogic.choice(override: .state(.exempt)), .state(.exempt))
    }

    func testDraftTracksChanges() throws {
        let sage = try XCTUnwrap(GradeEditorFixtures.cycle(2).rows.first { $0.userId == "u-sage" })
        var draft = GradeDraft(sage)
        XCTAssertEqual(draft.mode, .score)
        XCTAssertEqual(draft.finalCutInput, .points(42))
        XCTAssertEqual(draft, GradeDraft(sage))
        draft.finalCutText = "44"
        XCTAssertNotEqual(draft, GradeDraft(sage))
        draft.finalCutText = "abc"
        XCTAssertNil(draft.finalCutInput)
        draft.mode = .exempt
        XCTAssertEqual(draft.finalCutInput, .state(.exempt))
    }

    func testPacificWeeks() throws {
        // Wednesday Oct 7, 2026, 11 PM Pacific is already Thursday in UTC.
        let lateWednesday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-08T06:00:00Z"))
        XCTAssertEqual(GradeEditorLogic.dateKey(lateWednesday), "2026-10-07")
        XCTAssertEqual(GradeEditorLogic.weekStart(of: lateWednesday), "2026-10-05")
        XCTAssertEqual(GradeEditorLogic.shiftWeek("2026-10-05", by: 1), "2026-10-12")
        XCTAssertEqual(GradeEditorLogic.shiftWeek("2026-11-02", by: -1), "2026-10-26", "across the end of daylight saving")
    }

    func testParticipationSendsOnlyRealChangesCappedAtTheDay() throws {
        let week = try GradeEditorFixtures.participation("2026-10-05")
        let edits: [String: ParticipationEdit] = [
            "u-abby": ParticipationEdit(points: 20, notes: ""),          // unchanged
            "u-sage": ParticipationEdit(points: 15, notes: "Left early"), // same as pending
            "u-rio": ParticipationEdit(points: 25, notes: ""),           // new, over the max
            "u-kai": ParticipationEdit(points: 12, notes: "  Phone out  "),
        ]
        let entries = GradeEditorLogic.changedEntries(edits: edits, week: week, date: "2026-10-06")
        XCTAssertEqual(entries, [
            ParticipationEntryBody(userId: "u-kai", date: "2026-10-06", points: 12, notes: "Phone out"),
            ParticipationEntryBody(userId: "u-rio", date: "2026-10-06", points: 20, notes: ""),
        ])
        XCTAssertTrue(GradeEditorLogic.isDocked(points: 12, max: 20))
        XCTAssertFalse(GradeEditorLogic.isDocked(points: 20, max: 20))
    }

    func testDeepLinks() {
        XCTAssertEqual(GradeEditorRoute.deepLink(["grade-editor"], []), DeepLinkMatch(tab: .more, route: .gradeEditor(.home)))
        XCTAssertEqual(GradeEditorRoute.deepLink(["grades", "grade-editor"], []), DeepLinkMatch(tab: .more, route: .gradeEditor(.home)))
        XCTAssertNil(GradeEditorRoute.deepLink(["participation"], []), "APs use Participation too; it stays on the web")
    }
}

/// Request bodies and calls, through the stubbed network.
final class GradeEditorServiceTests: XCTestCase {
    private func service() -> GradeEditorService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GradeEditorService(client: PortalClient(portal: URL(string: "https://portal.example.edu")!,
                                                       session: URLSession(configuration: config), cookies: { [] }))
    }

    override func setUp() { UserDefaults.standard.removeObject(forKey: "InFocusStubSession") }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    private func body() throws -> [String: Any] {
        let data = try XCTUnwrap(StubProtocol.lastRequest?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSaveSendsExplicitNullsLikeTheWeb() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"userId":"u-rio","revised":false,"feedback":"","freeExtensionDays":0,"published":false}}"#.utf8)) }
        _ = try await service().save(SaveGradeBody(cycleNumber: 2, userId: "u-rio", finalCut: .state(.exempt), feedback: "Sick week", turnedInDate: nil))
        let sent = try body()
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/grades/admin")
        XCTAssertEqual(sent["action"] as? String, "save")
        XCTAssertTrue(sent["effortPoints"] is NSNull)
        XCTAssertEqual(sent["finalCutState"] as? String, "EXEMPT")
        XCTAssertTrue(sent["turnedInDate"] is NSNull, "null clears the date; leaving it out would keep it")
        XCTAssertEqual(sent["teamworkPoints"] as? Int, 0)
    }

    func testCheckInPublishAndNotes() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{}}"#.utf8)) }
        try await service().setCheckIn(cycleNumber: 2, userId: "u-sage", stage: .aRollBRoll, points: nil)
        var sent = try body()
        XCTAssertEqual(sent["action"] as? String, "setCheckIn")
        XCTAssertEqual(sent["stage"] as? String, "aRollBRoll")
        XCTAssertTrue(sent["points"] is NSNull, "null returns to automatic")

        try await service().setCheckIn(cycleNumber: 2, userId: "u-sage", stage: .pitching, points: .state(.ungraded))
        XCTAssertEqual(try body()["points"] as? String, "UNGRADED")

        try await service().setPublished(cycleNumber: 2, userId: "u-sage", published: true)
        sent = try body()
        XCTAssertEqual(sent["action"] as? String, "setPublish")
        XCTAssertEqual(sent["published"] as? Bool, true)

        try await service().setTotalNotes(userId: "u-otto", notes: "Check in")
        XCTAssertEqual(try body()["action"] as? String, "setTotalNotes")
    }

    func testReadsUseTheWebsQueries() async throws {
        StubProtocol.handler = { _ in (200, Data("{\"data\":\(GradeEditorFixtures.totalsJSON)}".utf8)) }
        _ = try await service().totals()
        XCTAssertEqual(StubProtocol.lastRequest?.url?.query, "view=totals")

        StubProtocol.handler = { _ in (200, Data(#"{"data":{"saved":3,"pending":true,"itemCount":1}}"#.utf8)) }
        let result = try await service().saveParticipation([ParticipationEntryBody(userId: "u-kai", date: "2026-10-06", points: 12, notes: "")])
        XCTAssertTrue(result.pending)
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/participation")
        XCTAssertEqual((try body()["entries"] as? [[String: Any]])?.first?["points"] as? Int, 12)
    }

    func testRefusalsComeBackAsWords() async {
        StubProtocol.handler = { _ in (400, Data(#"{"error":{"message":"This check-in is not due yet."}}"#.utf8)) }
        do {
            try await service().setCheckIn(cycleNumber: 3, userId: "u-kai", stage: .initialCut, points: .points(5))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This check-in is not due yet.")
        }
    }
}
