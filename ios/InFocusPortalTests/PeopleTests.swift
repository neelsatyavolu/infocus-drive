import XCTest
@testable import InFocusPortal

/// Members notes, Participation and exec extension grants: decoding, the web page rules,
/// deep links and the calls made. Fictional people only.
final class MembersTests: XCTestCase {
    private func payload() throws -> MembersPayload {
        try GradesFixtures.decode(MembersPayload.self, MembersService.sampleJSON)
    }

    func testDecodesMembers() throws {
        let payload = try payload()
        XCTAssertEqual(payload.cycles.map(\.cycleNumber), [1, 2])
        XCTAssertEqual(payload.cycles[1].focus, "Sports")
        XCTAssertEqual(payload.members.count, 3)
        XCTAssertEqual(payload.members[0].notesByCycle["0"], "Strong on camera. Wants to try editing.")
        XCTAssertTrue(payload.members[2].notesByCycle.isEmpty)
    }

    func testNoteKeysAndCoverage() throws {
        let payload = try payload()
        let notes = MembersLogic.notes(from: payload.members)
        XCTAssertEqual(notes["u-abby:1"], "Great interview list.")
        XCTAssertEqual(MembersLogic.parseKey("u-abby:1")?.userId, "u-abby")
        XCTAssertEqual(MembersLogic.parseKey("user:with:colons:3")?.userId, "user:with:colons")
        XCTAssertEqual(MembersLogic.parseKey("user:with:colons:3")?.cycle, 3)
        XCTAssertNil(MembersLogic.parseKey("nocolon"))
        XCTAssertNil(MembersLogic.parseKey(":2"))
        let tabs = [0, 1, 2]
        XCTAssertEqual(MembersLogic.tabsWithNotes(notes, memberId: "u-abby", tabs: tabs), [0, 1])
        XCTAssertEqual(MembersLogic.coverage([0, 2]), "Notes: General, Cycle 02")
        XCTAssertEqual(MembersLogic.coverage([]), "No notes yet")
        XCTAssertEqual(MembersLogic.tabTitle(0), "General")
        XCTAssertEqual(MembersLogic.tabTitle(3), "Cycle 03")
    }

    func testSearchFilterAndHeader() throws {
        let payload = try payload()
        let notes = MembersLogic.notes(from: payload.members)
        func ids(_ tab: Int, _ filter: MemberNoteFilter, _ search: String = "") -> [String] {
            MembersLogic.visible(payload.members, notes: notes, tab: tab, filter: filter, search: search).map(\.id)
        }
        XCTAssertEqual(ids(0, .all), ["u-abby", "u-otto", "u-sage"])
        XCTAssertEqual(ids(0, .with), ["u-abby"])
        XCTAssertEqual(ids(2, .without), ["u-abby", "u-sage"])
        XCTAssertEqual(ids(0, .all, "OTTO@"), ["u-otto"])
        XCTAssertEqual(MembersLogic.tabDescription(2, cycles: payload.cycles), "Cycle 2 · Sports")
        XCTAssertEqual(MembersLogic.tabDescription(5, cycles: payload.cycles), "Notes for package cycle 5.")
        XCTAssertTrue(MembersLogic.tabDescription(0, cycles: payload.cycles).hasPrefix("Standing notes"))
    }

    func testDeepLinks() {
        XCTAssertEqual(GradesRoute.deepLink(["members"], []), DeepLinkMatch(tab: .more, route: .grades(.members)))
        XCTAssertEqual(GradesRoute.deepLink(["participation"], []), DeepLinkMatch(tab: .more, route: .grades(.participation)))
        XCTAssertEqual(GradesRoute.deepLink(["grades", "participation"], [])?.route, .grades(.participation))
        XCTAssertNil(GradesRoute.deepLink(["members", "u-abby"], []))
        let portal = URL(string: "https://portal.example.edu")!
        XCTAssertEqual(DeepLink.resolve(URL(string: "https://portal.example.edu/members")!, portal: portal).route, .grades(.members))
        XCTAssertEqual(DeepLink.resolve(URL(string: "https://grades.portal.example.edu/participation")!, portal: portal).route,
                       .grades(.participation))
        XCTAssertEqual(DeepLink.resolve(URL(string: "https://portal.example.edu/participation")!, portal: portal).route,
                       .grades(.participation))
    }
}

@MainActor
final class MembersServiceTests: XCTestCase {
    private func client() -> PortalClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return PortalClient(portal: URL(string: "https://portal.example.edu")!,
                            session: URLSession(configuration: config), cookies: { [] })
    }

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "InFocusStubSession")
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    func testLoadsMembers() async throws {
        StubProtocol.handler = { _ in (200, Data(MembersService.sampleJSON.utf8)) }
        let payload = try await MembersService(client: client()).members()
        XCTAssertEqual(payload.members.first?.id, "u-abby")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/members")
    }

    func testStoreAutosavesTheNewestText() async throws {
        StubProtocol.handler = { request in
            if request.httpMethod == "PATCH" {
                return (200, Data("{\"data\":".utf8) + (request.httpBody ?? Data()) + Data("}".utf8))
            }
            return (200, Data(MembersService.sampleJSON.utf8))
        }
        let store = MembersStore(service: MembersService(client: client()), delay: .milliseconds(1))
        await store.load()
        XCTAssertEqual(store.note("u-otto", 2), "Check in about b-roll.")
        store.setNote("u-sage", 0, "Steady on sound.")
        XCTAssertEqual(store.noteState("u-sage", 0), .dirty)
        await store.persist(MembersLogic.key("u-sage", 0))
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/members/notes")
        let body = try JSONDecoder().decode(MemberNoteSave.self, from: request.httpBody ?? Data())
        XCTAssertEqual(body, MemberNoteSave(userId: "u-sage", cycleNumber: 0, notes: "Steady on sound."))
        XCTAssertEqual(store.noteState("u-sage", 0), .saved)
    }

    func testStoreShowsAFailedSave() async {
        StubProtocol.handler = { request in
            request.httpMethod == "PATCH" ? (400, Data(#"{"error":{"message":"Bad request"}}"#.utf8))
                : (200, Data(MembersService.sampleJSON.utf8))
        }
        let store = MembersStore(service: MembersService(client: client()), delay: .seconds(60))
        await store.load()
        store.setNote("u-abby", 1, "Changed")
        await store.persist(MembersLogic.key("u-abby", 1))
        XCTAssertEqual(store.noteState("u-abby", 1), .failed("Bad request"))
    }

    func testForbiddenReadsAsNotAvailable() async {
        StubProtocol.handler = { _ in (403, Data(#"{"error":{"message":"Forbidden"}}"#.utf8)) }
        let store = MembersStore(service: MembersService(client: client()))
        await store.load()
        guard case .failed(let message) = store.state else { return XCTFail("expected a failure") }
        XCTAssertEqual(message, "Members isn't available for this account.")
    }
}

/// Exec grants, grant-before-agreement, the decision email and the roster filters.
final class ExtensionGrantTests: XCTestCase {
    private let grantPayloadJSON = #"""
    {"data":{"canDecide":false,"canGrant":true,"currentUserId":"u-exec","approvalsRequired":2,
      "activeCycleNumber":2,"cycleNumbers":[1,2,3,4],
      "requests":[{"id":"r9","cycleNumber":2,"requestedDays":2,"grantedDays":null,"grantedUserIds":[],"producerGranted":false,
        "reason":"","status":"PENDING","createdAt":"2026-10-01T18:00:00.000Z","decidedAt":null,"groupTopic":"Robotics",
        "student":{"id":"u-sage","name":"Sage Example","email":"sage@example.edu"},
        "groupMembers":[{"userId":"u-sage","name":"Sage Example","email":"sage@example.edu"},
                        {"userId":"u-otto","name":"Otto Example","email":"otto@example.edu"}],
        "memberConsents":[{"userId":"u-sage","agreed":true,"name":"Sage Example"}],
        "memberConsentComplete":false,"canDecide":false,"canGrantPending":true,"approvalsRequired":2,"approvals":[]}]}}
    """#

    func testDecodesGrantFields() throws {
        let payload = try GradesFixtures.decode(ExtensionRequestsPayload.self, grantPayloadJSON)
        XCTAssertEqual(payload.activeCycleNumber, 2)
        XCTAssertEqual(payload.cycleNumbers, [1, 2, 3, 4])
        XCTAssertTrue(payload.requests[0].showsGrant)
        // Older answers without the fields still decode.
        let old = try GradesFixtures.decode(ExtensionRequestsPayload.self, GradesFixtures.producerExtensionsJSON)
        XCTAssertNil(old.cycleNumbers)
        XCTAssertFalse(old.requests[0].showsGrant)
    }

    func testDecodesGrantGroups() throws {
        let groups = try GradesFixtures.decode(GrantGroups.self, GradesFixtures.grantGroupsJSON).groups
        XCTAssertEqual(groups.map(\.id), ["row2", "row3"])
        XCTAssertEqual(groups[0].label, "Water polo season · Otto Example, Abby Example")
        XCTAssertEqual(groups[1].label, "Sage Example")
    }

    func testGrantDecisionBody() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let grant = ProducerDecision(requestId: "r9", approved: true, grantedDays: 2, grantedUserIds: ["u-sage"],
                                     grantWithoutAgreement: true)
        XCTAssertEqual(String(data: try encoder.encode(grant), encoding: .utf8),
                       #"{"approved":true,"grantWithoutAgreement":true,"grantedDays":2,"grantedUserIds":["u-sage"],"kind":"producer","requestId":"r9"}"#)
    }

    func testRosterFilters() throws {
        let json = #"""
        {"data":{"canEdit":true,"canAssignProducer":true,"activeCycleNumber":2,"cycles":[],
          "producers":[{"userId":"otto","name":"Otto Example","email":"otto@example.edu"}],
          "executives":[{"userId":"sage","name":"Sage Example","email":"sage@example.edu"}],
          "previousTeammatesByUser":{"abby":["juno"]},
          "rows":[
            {"id":"r1","groupMembers":"","memberUserIds":["abby","juno"],"assignedProducerUserId":"otto","assignedExecutiveProducerUserId":null},
            {"id":"r2","groupMembers":"","memberUserIds":[],"assignedProducerUserId":"otto","assignedExecutiveProducerUserId":"sage"},
            {"id":"r3","groupMembers":"","memberUserIds":["kai"],"assignedProducerUserId":"","assignedExecutiveProducerUserId":null}]}}
        """#
        let roster = try GradesFixtures.decode(RosterPayload.self, json)
        func ids(_ filter: RosterFilter, viewer: String?) -> [String] {
            roster.rows.filter { filter.matches($0, previous: roster.previousTeammatesByUser, viewerId: viewer) }.map(\.id)
        }
        XCTAssertEqual(ids(.all, viewer: nil), ["r1", "r2", "r3"])
        XCTAssertEqual(ids(.noProducer, viewer: nil), ["r3"])
        XCTAssertEqual(ids(.noMembers, viewer: nil), ["r2"])
        XCTAssertEqual(ids(.repeated, viewer: nil), ["r1"])
        XCTAssertEqual(ids(.mine, viewer: "otto"), ["r1"], "an assigned EP wins over the AP")
        XCTAssertEqual(ids(.mine, viewer: nil), [])
        XCTAssertEqual(RosterFilter.viewerId(email: "SAGE@example.edu", in: roster), "sage")
        XCTAssertNil(RosterFilter.viewerId(email: "juno@example.edu", in: roster))
    }
}

final class ExtensionGrantServiceTests: XCTestCase {
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

    func testLoadsGroupsForACycle() async throws {
        StubProtocol.handler = { _ in (200, Data(GradesFixtures.grantGroupsJSON.utf8)) }
        let groups = try await service().grantGroups(cycle: 3)
        XCTAssertEqual(groups.count, 2)
        let url = try XCTUnwrap(StubProtocol.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/extensions/grants")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "3")
    }

    func testPostsAGrant() async throws {
        StubProtocol.handler = { _ in (201, Data(#"{"data":{"id":"g1"}}"#.utf8)) }
        try await service().grant(NewExtensionGrant(progressRowId: "row2", days: 1.5, grantedUserIds: ["u-otto"], reason: "Sick week"))
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/extensions/grants")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["progressRowId"] as? String, "row2")
        XCTAssertEqual(body?["days"] as? Double, 1.5)
        XCTAssertEqual(body?["grantedUserIds"] as? [String], ["u-otto"])
    }

    func testEmailsTheGroup() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"configured":true,"sent":2,"failed":0}}"#.utf8)) }
        let sent = try await service().emailGroup(requestId: "r2")
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/extensions/requests/notify")
    }
}
