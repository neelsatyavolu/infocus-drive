import XCTest
@testable import InFocusPortal

/// Equipment and Livestreams: decoding the Portal's JSON and the web's rules for each action.
final class MessagesGearLivestreamTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
    }

    private var client: PortalClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return PortalClient(portal: portal, session: URLSession(configuration: config), cookies: { [] })
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    // MARK: Livestreams

    private let scheduleJSON = """
    {"data":{"semester":{"label":"Fall 2026","academicYearStart":2026,"term":"S1","start":"2026-08-13T07:00:00.000Z","end":"2026-12-19T07:59:59.000Z"},
     "requiredHours":8,"defaultCapacity":4,"canManage":false,"canSignup":true,"canAppointManagers":false,"canViewCompletion":false,
     "currentUserId":"me","managers":[],
     "mySignups":[{"id":"s1","eventId":"e2","status":"DENIED","availableFullEvent":true,"note":"","createdAt":"2026-10-01T18:00:00.000Z"}],
     "pendingSignups":[],
     "events":[
      {"id":"e1","title":"Varsity Football vs Burlingame","startsAt":"2026-10-10T01:00:00.000Z","location":"Viking Stadium","status":"SCHEDULED",
       "availability":"PUBLIC","hours":3,"capacity":4,"notes":"","manager":{"id":"m","name":"Sage Example","email":"sage@example.edu"},
       "attendees":[{"id":"me","name":"Abby Example","email":"abby@example.edu","creditHours":null}],"attendeeCount":1,"openSlots":3,
       "capacityTone":"open","mySignup":{"id":"s0","status":"APPROVED","availableFullEvent":true},"pendingSignupCount":0},
      {"id":"e2","title":"Fall Choir Concert","startsAt":"2026-10-15T02:00:00.000Z","location":"","status":"SCHEDULED",
       "availability":"UNCONFIRMED","hours":null,"capacity":2,"notes":"Wear black","manager":null,
       "attendees":[],"attendeeCount":0,"openSlots":2,"capacityTone":"open","mySignup":{"id":"s1","status":"DENIED","availableFullEvent":true},"pendingSignupCount":0},
      {"id":"e3","title":"Water Polo","startsAt":"2026-09-01T01:00:00.000Z","location":"Pool","status":"COMPLETED",
       "availability":"PUBLIC","hours":2,"capacity":1,"notes":"","manager":null,
       "attendees":[{"id":"x","name":"Otto Example","email":null,"creditHours":2}],"attendeeCount":1,"openSlots":0,"capacityTone":"full","mySignup":null,"pendingSignupCount":0}]}}
    """

    func testDecodesTheScheduleAndAppliesTheWebsSignupRules() throws {
        let schedule = try decode(LivestreamSchedule.self, scheduleJSON)
        XCTAssertEqual(schedule.events.count, 3)
        XCTAssertEqual(schedule.event("e1")?.manager?.name, "Sage Example")
        XCTAssertEqual(SignupAction.for(schedule.event("e1")!, schedule: schedule), .onCrew)
        XCTAssertEqual(SignupAction.for(schedule.event("e2")!, schedule: schedule), .request(again: true))
        XCTAssertEqual(SignupAction.for(schedule.event("e3")!, schedule: schedule), .closed("Completed"))
        XCTAssertEqual(schedule.event("e1")?.attendees.first?.firstName, "Abby")
    }

    func testManagersCantRequestAndFullEventsSayFull() throws {
        let schedule = try decode(LivestreamSchedule.self, scheduleJSON.replacingOccurrences(of: #""canSignup":true"#, with: #""canSignup":false"#))
        XCTAssertEqual(SignupAction.for(schedule.event("e2")!, schedule: schedule), .managerCannotSignUp)
        let full = try decode(LivestreamSchedule.self, scheduleJSON.replacingOccurrences(of: #""openSlots":2,"capacityTone":"open""#, with: #""openSlots":0,"capacityTone":"full""#))
        XCTAssertEqual(SignupAction.for(full.event("e2")!, schedule: full), .full)
    }

    func testScheduleSplitsUpcomingSoonestFirstAndEarlierNewestFirst() throws {
        let schedule = try decode(LivestreamSchedule.self, scheduleJSON)
        let now = ISO8601DateFormatter().date(from: "2026-10-02T19:00:00Z")!
        let split = LivestreamsModel.split(schedule.events, now: now)
        XCTAssertEqual(split.upcoming.map(\.id), ["e1", "e2"])
        XCTAssertEqual(split.earlier.map(\.id), ["e3"])
    }

    func testSignupAndReviewRequests() async throws {
        StubProtocol.handler = { _ in (201, Data(#"{"data":{"id":"s9","status":"PENDING"}}"#.utf8)) }
        let service = LivestreamService.live(client)
        try await service.requestSignup("e1", "Leaving at halftime")
        var request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/livestreams/signups")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["eventId"] as? String, "e1")
        XCTAssertEqual(body["note"] as? String, "Leaving at halftime")
        XCTAssertEqual(body["availableFullEvent"] as? Bool, true)

        try await service.review("s9", false)
        request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/livestreams/signups/s9")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String], ["status": "DENIED"])
    }

    // MARK: Equipment

    func testDecodesMyGear() throws {
        let mine = try decode(MyEquipment.self, """
        {"data":{"overdueAfterHours":72,
         "out":[{"id":"cam","name":"Camera A","barcode":"CAM-1","checkedOutAt":"2026-10-01T12:00:00.000Z","dueAt":"2026-10-04T12:00:00.000Z","overdue":false}],
         "held":[{"id":"tri","name":"Tripod","barcode":"TRI-3"}],
         "requests":[{"id":"r1","status":"APPROVED","fulfilled":true,"createdAt":"2026-09-30T12:00:00.000Z","items":[{"id":"cam","name":"Camera A","barcode":"CAM-1"}]},
                     {"id":"r2","status":"PENDING","fulfilled":false,"createdAt":"2026-10-02T12:00:00.000Z","items":[]}]}}
        """)
        XCTAssertEqual(mine.out.first?.barcode, "CAM-1")
        XCTAssertEqual(mine.held.map(\.name), ["Tripod"])
        XCTAssertEqual(mine.requests.map(\.word), ["Fulfilled", "Pending"])
        XCTAssertFalse(mine.isEmpty)
    }

    func testManagerRequestActionsFollowTheWebsRules() throws {
        func item(out: Bool = false, held: String? = nil) -> String {
            #"{"item":{"id":"i","name":"Mic","barcode":"MIC-1","checkedOut":\#(out),"checkedOutAt":null,"onHoldForStudentId":\#(held.map { "\"\($0)\"" } ?? "null"),"archivedAt":null,"metadata":null}}"#
        }
        func request(_ status: String, _ items: String) throws -> ManagedRequests.Request {
            try decode(ManagedRequests.self, """
            {"data":{"requests":[{"id":"r","status":"\(status)","email":"otto@example.edu","createdAt":"2026-10-02T12:00:00.000Z",
              "student":{"id":"s","name":"Otto Example","studentId":"950001","email":"otto@example.edu"},"items":[\(items)]}]}}
            """).requests[0]
        }
        let pending = try request("PENDING", item())
        XCTAssertTrue(pending.canApprove)
        XCTAssertTrue(pending.canDeny)
        XCTAssertFalse(try request("PENDING", item(held: "other")).canApprove)
        let approvedHeld = try request("APPROVED", item(held: "s"))
        XCTAssertFalse(approvedHeld.canApprove)
        XCTAssertTrue(approvedHeld.canDeny)
        XCTAssertFalse(try request("APPROVED", item(out: true)).canDeny)
        XCTAssertFalse(try request("DENIED", item()).canDeny)
    }

    func testOverdueAfterSeventyTwoHours() {
        let now = Date()
        let item = { (hours: Double) in
            ManagedOut.Item(id: "i", name: "Mic", barcode: "M", checkedOut: true, checkedOutAt: now.addingTimeInterval(-hours * 3600),
                            checkedOutBy: nil, onHoldForStudent: nil, tookSdCard: nil)
        }
        XCTAssertTrue(item(73).isOverdue(now: now))
        XCTAssertFalse(item(71).isOverdue(now: now))
    }

    func testGearSearchAndFriendlyRequestErrors() {
        let gear = [GearItem(id: "1", name: "Rode Shotgun Mic", barcode: "MIC-02"), GearItem(id: "2", name: "Tripod", barcode: "TRI-11")]
        XCTAssertEqual(EquipmentModel.search(gear, query: "mic").map(\.id), ["1"])
        XCTAssertEqual(EquipmentModel.search(gear, query: "tri-1").map(\.id), ["2"])
        XCTAssertTrue(PortalError.gearRequestMessage(PortalError.notFound).contains("student ID"))
        XCTAssertTrue(PortalError.gearRequestMessage(PortalError.server(status: 409, message: "Conflict")).contains("Someone just took"))
        XCTAssertEqual(GearIcon.symbol(for: "Wireless Lav Kit"), "mic.fill")
        XCTAssertEqual(GearIcon.symbol(for: "Mystery box"), "shippingbox.fill")
    }

    func testEquipmentRequestsHitTheWebsEndpoints() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"id":"x"}}"#.utf8)) }
        let service = EquipmentService.live(client)
        try await service.request(GearRequestBody(studentName: "Abby Example", studentId: "950003", email: "abby@example.edu", barcodes: ["MIC-02"]))
        var request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/equipment/public/requests")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["barcodes"] as? [String], ["MIC-02"])

        try await service.decide("r1", true)
        request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/equipment/manage/requests")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String], ["id": "r1", "action": "approve"])

        try await service.outAction("cam", "release-hold")
        request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String], ["action": "release-hold", "itemId": "cam"])
    }
}
