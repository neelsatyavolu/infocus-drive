import XCTest
@testable import InFocusPortal

/// Grades and extensions: decoding the Portal's JSON, the web page's display
/// rules, request rules and the calls made. Fictional people only.
final class GradesTests: XCTestCase {
    private func grades() throws -> GradesMe {
        try GradesFixtures.decode(GradesMe.self, GradesFixtures.gradesJSON)
    }

    private func requests() throws -> ExtensionRequestsPayload {
        try GradesFixtures.decode(ExtensionRequestsPayload.self, GradesFixtures.extensionsJSON)
    }

    func testDecodesGradesMe() throws {
        let grades = try grades()
        XCTAssertEqual(grades.estimated?.letter, "A-")
        XCTAssertEqual(grades.estimated?.packages.finalCutPoints.first ?? nil, 44)
        XCTAssertNil(grades.estimated?.packages.livestreamPoints)
        XCTAssertEqual(grades.cycles.count, 4)
        XCTAssertEqual(grades.gradebook?.weeks.last?.days[1].notes, "Left the studio early.")
    }

    func testDecodesAnExecWithoutAGradebook() throws {
        let json = #"{"data":{"role":"EXECUTIVE_PRODUCER","isAdmin":true,"summary":{"publishedCycleCount":0,"averageTotal":null,"averagePercentage":null,"extensionsRemaining":null},"cycles":[]}}"#
        let grades = try GradesFixtures.decode(GradesMe.self, json)
        XCTAssertNil(grades.estimated)
        XCTAssertNil(grades.gradebook)
    }

    func testCategoryTotalsMatchTheWeb() throws {
        let grades = try grades()
        // One graded final cut (44/50) + check-ins 20/20 and 15/15.
        XCTAssertEqual(GradesPresentation.packageTotals(grades.estimated), .init(earned: 79, possible: 85))
        XCTAssertEqual(GradesPresentation.packageTotals(grades.estimated).percent, 92.9)
        // Livestream held back and portfolio unmarked: nothing gradeable yet.
        XCTAssertEqual(GradesPresentation.otherTotals(grades.estimated), .init(earned: 0, possible: 0))
        XCTAssertNil(GradesPresentation.otherTotals(grades.estimated).percent)
        XCTAssertEqual(GradesPresentation.participationTotals(grades.estimated), .init(earned: 176, possible: 190))
    }

    func testCycleTitlesAndSemesterFilter() throws {
        let grades = try grades()
        XCTAssertEqual(GradesPresentation.cycleTitle(grades.cycles[0]), "Cycle 1 · Back to school")
        XCTAssertEqual(GradesPresentation.cycleTitle(grades.cycles[2]), "Cycle 3 · March")
        XCTAssertEqual(GradesPresentation.semesterCycles(grades).map(\.cycleNumber), [1, 2, 3])
        XCTAssertEqual(GradesPresentation.semesterTerm("26-27 S2"), 2)
        XCTAssertNil(GradesPresentation.semesterTerm("2026"))
        let scores = GradesPresentation.scores(for: grades.cycles[1], in: grades)
        XCTAssertNil(scores.finalCut)
        XCTAssertEqual(scores.checkIn, 15)
        XCTAssertEqual(scores.checkInMax, 15)
    }

    func testCurrentWeekAndLabels() throws {
        let weeks = try grades().gradebook!.weeks
        XCTAssertEqual(GradesPresentation.currentWeekIndex(weeks, today: "2026-09-23"), 0)
        XCTAssertEqual(GradesPresentation.currentWeekIndex(weeks, today: "2026-10-30"), 1)
        XCTAssertEqual(GradesPresentation.currentWeekIndex([], today: "2026-10-30"), 0)
        XCTAssertEqual(GradesPresentation.dayKind("NONE"), "Class")
        XCTAssertEqual(GradesPresentation.points(7.5), "7.5")
        XCTAssertEqual(GradesPresentation.points(40), "40")
    }

    func testExtensionDays() {
        XCTAssertTrue(ExtensionRequest.isValidDays(0.1))
        XCTAssertTrue(ExtensionRequest.isValidDays(2.5))
        XCTAssertFalse(ExtensionRequest.isValidDays(2.25))
        XCTAssertFalse(ExtensionRequest.isValidDays(0))
        XCTAssertFalse(ExtensionRequest.isValidDays(31))
        XCTAssertEqual(ExtensionRequest.roundDays(0.1 + 0.5), 0.6)
        XCTAssertTrue(ExtensionRequest.isValidDays(ExtensionRequest.roundDays(0.1 + 0.5)))
        XCTAssertEqual(ExtensionRequest.daysLabel(1), "+1 day")
        XCTAssertEqual(ExtensionRequest.daysLabel(1.5), "+1.5 days")
    }

    func testWhoNeedsToRespond() throws {
        let payload = try requests()
        let pending = payload.requests[0]
        XCTAssertTrue(pending.needsConsent(from: "u-abby"))
        XCTAssertFalse(pending.needsConsent(from: "u-otto"))
        XCTAssertEqual(pending.agreedCount, 1)
        XCTAssertEqual(payload.needingMe.map(\.id), ["r1"])
        XCTAssertEqual(payload.open.map(\.id), ["r0"])
        XCTAssertTrue(payload.denied.isEmpty)
        XCTAssertTrue(pending.progressLine.contains("waiting for the whole group"))
    }

    func testProducerTermsLockAfterTheFirstApproval() throws {
        let payload = try GradesFixtures.decode(ExtensionRequestsPayload.self, GradesFixtures.producerExtensionsJSON)
        let request = payload.requests[0]
        XCTAssertTrue(request.awaitsDecision)
        XCTAssertEqual(request.lockedTerms(for: "u-producer")?.days, 1.5)
        XCTAssertEqual(request.lockedTerms(for: "u-producer")?.userIds, ["u-otto", "u-abby"])
        XCTAssertNil(request.lockedTerms(for: "p1"), "the first approver can still change their own terms")
        XCTAssertEqual(payload.requests[1].denials.first?.reason, "The deadline was announced two weeks ahead.")
        XCTAssertEqual(payload.denied.map(\.id), ["r2"])
    }

    func testDeepLinks() {
        XCTAssertEqual(GradesRoute.deepLink(["grades"], [])?.route, .grades(.grades))
        XCTAssertEqual(GradesRoute.deepLink(["grades", "grades"], [])?.route, .grades(.grades))
        XCTAssertNil(GradesRoute.deepLink(["grades", "grade-editor"], []))
        XCTAssertEqual(GradesRoute.deepLink(["extension-requests", "r1"], [])?.route, .grades(.extensionRequest(id: "r1")))
        XCTAssertEqual(GradesRoute.deepLink(["extensions"], [])?.route, .grades(.extensions))
    }

    func testDecisionBodies() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let deny = ProducerDecision(requestId: "r1", approved: false, reason: "Too late")
        XCTAssertEqual(String(data: try encoder.encode(deny), encoding: .utf8),
                       #"{"approved":false,"kind":"producer","reason":"Too late","requestId":"r1"}"#)
        let member = MemberDecision(requestId: "r1", agreed: true)
        XCTAssertEqual(String(data: try encoder.encode(member), encoding: .utf8),
                       #"{"agreed":true,"kind":"member","requestId":"r1"}"#)
    }
}

/// The calls themselves, through the stubbed network.
final class GradesServiceTests: XCTestCase {
    private func service() -> GradesService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return GradesService(client: PortalClient(portal: URL(string: "https://portal.example.edu")!,
                                                  session: URLSession(configuration: config), cookies: { [] }))
    }

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "InFocusStubSession")
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    func testLoadsGradesFromThePortal() async throws {
        StubProtocol.handler = { _ in (200, Data(GradesFixtures.gradesJSON.utf8)) }
        let grades = try await service().grades()
        XCTAssertEqual(grades.estimated?.letter, "A-")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/grades/me")
    }

    func testFilesARequest() async throws {
        StubProtocol.handler = { _ in (201, Data(#"{"data":{"id":"new"}}"#.utf8)) }
        try await service().requestExtension(NewExtensionRequest(cycleNumber: 2, requestedDays: 1.5, reason: "Interview moved"))
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/extensions/requests")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["cycleNumber"] as? Int, 2)
        XCTAssertEqual(body?["requestedDays"] as? Double, 1.5)
    }

    func testShowsThePortalsReasonWhenARequestIsRefused() async {
        StubProtocol.handler = { _ in
            (400, Data(#"{"error":{"message":"You are not assigned to a package group for this cycle."}}"#.utf8))
        }
        do {
            try await service().requestExtension(NewExtensionRequest(cycleNumber: 5, requestedDays: 1, reason: ""))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "You are not assigned to a package group for this cycle.")
        }
    }

    func testAgreesAsAMember() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"status":"PENDING"}}"#.utf8)) }
        try await service().respondAsMember(requestId: "r1", agreed: true)
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PATCH")
    }
}
