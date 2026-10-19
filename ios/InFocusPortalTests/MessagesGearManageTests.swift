import XCTest
@testable import InFocusPortal

/// Equipment managers' Inventory and Managers, the livestream editor, credit roster and
/// managers, Slack file downloads, and the Equipment deep links.
final class MessagesGearManageTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
    }

    private var client: PortalClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return PortalClient(portal: portal, session: URLSession(configuration: config), cookies: { [] })
    }

    private func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    // MARK: Equipment deep links

    func testEquipmentLinksOpenTheRightSection() {
        func resolve(_ url: String) -> DeepLinkMatch { DeepLink.resolve(URL(string: url)!, portal: portal) }
        XCTAssertEqual(resolve("https://portal.example.edu/equipment"), DeepLinkMatch(tab: .more, route: .messages(.equipment)))
        XCTAssertEqual(resolve("https://portal.example.edu/equipment/request"),
                       DeepLinkMatch(tab: .more, route: .messages(.equipmentAt(.request))))
        XCTAssertEqual(resolve("https://portal.example.edu/equipment/manage"),
                       DeepLinkMatch(tab: .more, route: .messages(.equipmentAt(.manage))))
        XCTAssertEqual(resolve("https://equipment.portal.example.edu/manage"),
                       DeepLinkMatch(tab: .more, route: .messages(.equipmentAt(.manage))))
        XCTAssertEqual(resolve("https://equipment.portal.example.edu/request"),
                       DeepLinkMatch(tab: .more, route: .messages(.equipmentAt(.request))))
        XCTAssertEqual(resolve("https://portal.example.edu/livestreams/e1"),
                       DeepLinkMatch(tab: .more, route: .messages(.livestream(id: "e1"))))
    }

    func testManageFallsBackToMyGearForNonManagers() {
        XCTAssertEqual(EquipmentScreen.visible(.manage, canManage: false), .mine)
        XCTAssertEqual(EquipmentScreen.visible(.manage, canManage: true), .manage)
        XCTAssertEqual(EquipmentScreen.visible(.request, canManage: false), .request)
    }

    // MARK: Inventory

    private let inventoryJSON = """
    {"data":{"items":[
     {"id":"a","name":"Canon T8i","barcode":"CAM-1","checkedOut":false,"checkedOutAt":null,"checkedOutById":null,
      "onHoldForStudentId":null,"holdRequestId":null,"archivedAt":null,"checkedOutBy":null,"onHoldForStudent":null},
     {"id":"b","name":"Rode Mic","barcode":"MIC-2","checkedOut":true,"checkedOutAt":"2026-10-01T12:00:00.000Z","checkedOutById":"s1",
      "onHoldForStudentId":null,"holdRequestId":null,"archivedAt":null,
      "checkedOutBy":{"id":"s1","name":"Otto Example","studentId":"950001","email":"otto@example.edu"},"onHoldForStudent":null},
     {"id":"c","name":"Tripod","barcode":"TRI-3","checkedOut":false,"checkedOutAt":null,"checkedOutById":null,
      "onHoldForStudentId":"s2","holdRequestId":"r1","archivedAt":null,"checkedOutBy":null,
      "onHoldForStudent":{"id":"s2","name":null,"studentId":"950002","email":null}}]}}
    """

    func testDecodesInventoryWithEachItemsState() throws {
        let items = try decode(ManagedOut.self, inventoryJSON).items
        XCTAssertEqual(items.map(\.state), [.in, .out, .held])
        XCTAssertEqual(items[1].checkedOutBy?.label, "Otto Example")
        XCTAssertEqual(items[2].onHoldForStudent?.label, "950002", "no name: the student ID")
        XCTAssertEqual(EquipmentModel.searchItems(items, query: "mic").map(\.id), ["b"])
        XCTAssertEqual(EquipmentModel.searchItems(items, query: "tri-3").map(\.id), ["c"])
        XCTAssertEqual(EquipmentModel.searchItems(items, query: " ").count, 3)
    }

    func testOutFilters() throws {
        let items = try decode(ManagedOut.self, inventoryJSON).items
        let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
        XCTAssertEqual(items.filter { OutFilter.out.includes($0, now: now) }.map(\.id), ["b"])
        XCTAssertEqual(items.filter { OutFilter.held.includes($0, now: now) }.map(\.id), ["c"])
        XCTAssertEqual(items.filter { OutFilter.overdue.includes($0, now: now) }.map(\.id), ["b"])
        XCTAssertEqual(items.filter { OutFilter.all.includes($0, now: now) }.count, 3)
    }

    func testInventoryRequestsHitTheWebsEndpoints() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"id":"x"}}"#.utf8)) }
        let service = EquipmentService.live(client)

        try await service.addItem(NewGearBody(name: "Canon T8i", barcode: "CAM-9"))
        var request = StubProtocol.lastRequest
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/api/equipment/manage/items")
        XCTAssertEqual(try jsonBody(request) as? [String: String], ["name": "Canon T8i", "barcode": "CAM-9"])

        try await service.updateItem(GearPatchBody(id: "a", archived: true))
        request = StubProtocol.lastRequest
        XCTAssertEqual(request?.httpMethod, "PATCH")
        let archive = try jsonBody(request)
        XCTAssertEqual(archive["id"] as? String, "a")
        XCTAssertEqual(archive["archived"] as? Bool, true)
        XCTAssertNil(archive["name"], "blank fields are left out, not sent as null")

        try await service.updateItem(GearPatchBody(id: "a", name: "Canon R50", barcode: "CAM-1"))
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as? [String: String], ["id": "a", "name": "Canon R50", "barcode": "CAM-1"])
    }

    func testInventoryConflictsSayWhy() {
        let conflict = PortalError.server(status: 409, message: "Conflict")
        XCTAssertTrue(PortalError.inventoryMessage(conflict, archiving: false).contains("already uses that code"))
        XCTAssertTrue(PortalError.inventoryMessage(conflict, archiving: true).contains("Only items that are in"))
    }

    // MARK: Equipment managers

    func testDecodesManagersAndMembers() throws {
        let managers = try decode(ManagerList.self, """
        {"data":{"managers":[{"id":"m1","userId":"u1","createdAt":"2026-09-01T12:00:00.000Z",
          "user":{"id":"u1","name":"Sage Example","nickname":"Sage","email":"sage@example.edu"}},
          {"id":"m2","userId":"u2","createdAt":"2026-09-02T12:00:00.000Z","user":null}]}}
        """).managers
        XCTAssertEqual(managers.map(\.label), ["Sage", "Member"])

        let users = try decode([PortalMember].self, """
        {"data":[{"id":"u3","email":"abby@example.edu","name":"Abby Example","nickname":null,"createdAt":"2026-08-01T00:00:00.000Z"},
                 {"id":"u4","email":"otto@example.edu","name":null,"nickname":null,"createdAt":"2026-08-01T00:00:00.000Z"}]}
        """)
        XCTAssertEqual(users.map(\.label), ["Abby Example", "otto@example.edu"])
        XCTAssertTrue(users[0].matches("abby@"))
        XCTAssertTrue(users[0].matches("example"))
        XCTAssertFalse(users[1].matches("Sage"))
    }

    func testManagerAppointAndRemove() async throws {
        StubProtocol.handler = { _ in (201, Data(#"{"data":{"id":"m1"}}"#.utf8)) }
        let gear = EquipmentService.live(client)
        try await gear.addManager("u1")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/equipment/manage/managers")
        XCTAssertEqual(try jsonBody(StubProtocol.lastRequest) as? [String: String], ["userId": "u1"])
        try await gear.removeManager("u1")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.query, "userId=u1")

        let streams = LivestreamService.live(client)
        try await streams.addManager("u2")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/livestreams/managers")
        try await streams.removeManager("u2")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/livestreams/managers")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.query, "userId=u2")
    }

    // MARK: Livestream editor

    private func event() throws -> LivestreamEvent {
        try decode(LivestreamEvent.self, """
        {"data":{"id":"e1","title":"Varsity Football vs Gunn","startsAt":"2026-10-10T01:00:00.000Z","arrivesAt":"2026-10-10T00:15:00.000Z",
         "location":"Viking Stadium","status":"SCHEDULED","availability":"PUBLIC","hours":2.5,"capacity":4,"notes":"Press box",
         "manager":{"id":"m","name":"Sage Example","email":"sage@example.edu"},
         "attendees":[{"id":"a","name":"Abby Example","email":"abby@example.edu","creditHours":null},
                      {"id":"o","name":"Otto Example","email":null,"creditHours":1.5}],
         "attendeeCount":2,"openSlots":2,"capacityTone":"open","mySignup":null,"pendingSignupCount":0}}
        """)
    }

    func testScheduleDecodesManagersAndEditorFields() throws {
        let schedule = try decode(LivestreamSchedule.self, """
        {"data":{"semester":{"label":"Fall 2026"},"requiredHours":8,"defaultCapacity":5,"canManage":true,"canSignup":true,
         "canAppointManagers":true,"canViewCompletion":true,"currentUserId":"me",
         "managers":[{"id":"m","name":"Sage Example","email":"sage@example.edu"}],"mySignups":[],"pendingSignups":[],"events":[]}}
        """)
        XCTAssertTrue(schedule.canAppointManagers)
        XCTAssertTrue(schedule.canViewCompletion)
        XCTAssertEqual(schedule.managers.map(\.label), ["Sage Example"])
        XCTAssertEqual(schedule.defaultCapacity, 5)

        let event = try event()
        XCTAssertEqual(event.attendees.map(\.creditHours), [nil, 1.5])
        XCTAssertNotNil(event.arrivesAt)
    }

    func testFormFromEventAndComplete() throws {
        let form = LivestreamEventForm(event: try event(), complete: true)
        XCTAssertEqual(form.status, .completed)
        XCTAssertEqual(form.hours, "2.5")
        XCTAssertEqual(form.capacity, "4")
        XCTAssertEqual(form.manager?.id, "m")
        XCTAssertEqual(form.credits, ["a": "", "o": "1.5"])
        XCTAssertTrue(form.validate().isEmpty)
    }

    func testFormChecksMatchTheWeb() {
        var form = LivestreamEventForm(now: Date(), capacity: 4)
        var errors = form.validate()
        XCTAssertNotNil(errors.fields[.title])

        form.title = "Choir Concert"
        form.hours = "2.3"
        form.capacity = "60"
        form.crew = [LivestreamPerson(id: "a", name: "Abby Example")]
        form.credits = ["a": "25"]
        errors = form.validate()
        XCTAssertEqual(errors.fields[.hours], LivestreamEventForm.hoursError)
        XCTAssertEqual(errors.fields[.capacity], LivestreamEventForm.capacityError)
        XCTAssertEqual(errors.credits, ["a"])

        form.hours = "2.25"
        form.capacity = ""
        form.credits = ["a": "0.75"]
        XCTAssertTrue(form.validate().isEmpty)

        form.status = .completed
        form.hours = ""
        XCTAssertNotNil(form.validate().fields[.completedHours], "the API refuses Completed without hours")

        XCTAssertTrue(LivestreamEventForm.validHours(""))
        XCTAssertFalse(LivestreamEventForm.validHours("-1"))
        XCTAssertFalse(LivestreamEventForm.validHours("abc"))
        XCTAssertEqual(LivestreamEventForm.format(3), "3")
        XCTAssertEqual(LivestreamEventForm.format(0.25), "0.25")
    }

    func testCrewAddAndRemove() {
        var form = LivestreamEventForm()
        let abby = LivestreamPerson(id: "a", name: "Abby Example")
        form.add(abby)
        form.add(abby)
        XCTAssertEqual(form.crew.map(\.id), ["a"])
        form.credits["a"] = "2"
        form.remove("a")
        XCTAssertTrue(form.crew.isEmpty)
        XCTAssertNil(form.credits["a"])
    }

    func testBodySendsNullsAndArrivalOnTheStartDay() throws {
        var form = LivestreamEventForm(event: try event())
        form.hours = ""
        form.manager = nil
        let pacific = ISO8601DateFormatter()
        // Starts Fri Oct 9, 6:00 PM Pacific; arrival picked as 5:15 PM on another day.
        form.startsAt = pacific.date(from: "2026-10-10T01:00:30Z")!
        form.arrivesAt = pacific.date(from: "2026-12-01T01:15:00Z")!

        let data = try PortalJSON.encoder().encode(form.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(body["hours"] is NSNull)
        XCTAssertTrue(body["managerUserId"] is NSNull)
        XCTAssertEqual(body["startsAt"] as? String, "2026-10-10T01:00:00.000Z", "whole minutes, like datetime-local")
        XCTAssertEqual(body["arrivesAt"] as? String, "2026-10-10T00:15:00.000Z")
        XCTAssertEqual(body["status"] as? String, "SCHEDULED")
        XCTAssertEqual(body["availability"] as? String, "PUBLIC")
        XCTAssertEqual(body["attendeeUserIds"] as? [String], ["a", "o"])
        let credits = try XCTUnwrap(body["attendeeCredits"] as? [[String: Any]])
        XCTAssertTrue(credits[0]["creditHours"] is NSNull)
        XCTAssertEqual(credits[1]["creditHours"] as? Double, 1.5)
    }

    func testEventSaveAndDeleteHitTheWebsEndpoints() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"id":"e1"}}"#.utf8)) }
        let service = LivestreamService.live(client)
        let body = LivestreamEventForm(event: try event()).body

        try await service.saveEvent(nil, body)
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/livestreams/events")

        try await service.saveEvent("e1", body)
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/livestreams/events/e1")

        try await service.deleteEvent("e1")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/livestreams/events/e1")
    }

    // MARK: Credit roster

    func testDecodesCompletionAndFilters() async throws {
        let json = """
        {"data":{"semester":{"label":"Fall 2026","start":"2026-08-13T07:00:00.000Z","end":"2026-12-19T07:59:59.000Z"},
         "requiredHours":8,"requiredManagedEvents":2,"maxPoints":10,"completedEventCount":3,
         "rows":[{"userId":"a","name":"Abby Example","email":"abby@example.edu","completedHours":3,"completedEvents":1,"requiredHours":8,
                  "isManager":false,"managedEvents":0,"requiredManagedEvents":2,"creditPercent":38,"scheduledHours":2.5,"scheduledEvents":1,
                  "projectedPercent":69,"points":3.8},
                 {"userId":"s","name":"Sage Example","email":null,"completedHours":0,"completedEvents":0,"requiredHours":8,
                  "isManager":true,"managedEvents":2,"requiredManagedEvents":2,"creditPercent":100,"scheduledHours":0,"scheduledEvents":0,
                  "projectedPercent":100,"points":10}]}}
        """
        let completion = try decode(LivestreamCompletion.self, json)
        XCTAssertEqual(completion.completedEventCount, 3)
        XCTAssertEqual(completion.rows[0].summary, "3 / 8 h (+2.5 h signed up) · 38% · 1 livestream")
        XCTAssertEqual(completion.rows[1].summary, "2 / 2 managed · 100%")
        XCTAssertEqual(LivestreamCompletion.filter(completion.rows, query: "", .below).map(\.id), ["a"])
        XCTAssertEqual(LivestreamCompletion.filter(completion.rows, query: "sage", .all).map(\.id), ["s"])

        StubProtocol.handler = { _ in (200, Data(json.utf8)) }
        _ = try await LivestreamService.live(client).completion()
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/livestreams/completion")

        StubProtocol.handler = { _ in (200, Data(#"{"data":{"members":[{"id":"u","name":"Otto Example","nickname":"Otto","email":null}]}}"#.utf8)) }
        let members = try await LivestreamService.live(client).members()
        XCTAssertEqual(members.map(\.label), ["Otto"])
    }

    // MARK: Slack files

    func testFileNamesComeFromThePortalOrTheTitle() {
        XCTAssertEqual(PortalFileDownload.fileName("rundown.pdf", fallback: "Rundown"), "rundown.pdf")
        XCTAssertEqual(PortalFileDownload.fileName(nil, fallback: "Show notes"), "Show notes")
        XCTAssertEqual(PortalFileDownload.fileName("Unknown", fallback: ""), "attachment")
        XCTAssertEqual(PortalFileDownload.fileName("a/b:c.png", fallback: "x"), "a-b-c.png")
    }
}
