import XCTest
@testable import InFocusPortal

/// Report and Block (App Review Guideline 1.2).
final class ModerationTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    override func tearDown() {
        SampleMode.set(false)
        SampleMode.resetBlocked()
        StubProtocol.handler = nil
        super.tearDown()
    }

    private func client(_ seen: PathLog, bodies: BodyLog) -> PortalClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { request in
            seen.add(request.url?.path ?? "")
            bodies.add(request.httpBody ?? Data())
            return (201, Data(#"{"data":{"reported":true,"notified":2}}"#.utf8))
        }
        return PortalClient(portal: portal, session: URLSession(configuration: config), cookies: { [] })
    }

    func testAReportCarriesTheMessageAndAnOptionalReason() async throws {
        let seen = PathLog(), bodies = BodyLog()
        var report = ContentReport.chat("m1")
        report.reason = ContentReporter.reason("  rude \n")
        try await ContentReporter.send(report, client: client(seen, bodies: bodies))
        XCTAssertEqual(seen.paths, ["/api/hub-chat/report"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies.last) as? [String: String])
        XCTAssertEqual(json, ["kind": "chat", "messageId": "m1", "reason": "rude"])
        XCTAssertNil(ContentReporter.reason("   "))
        XCTAssertEqual(ContentReporter.reason(String(repeating: "x", count: 600))?.count, 500)
    }

    func testCommentReportsNameTheComment() throws {
        let data = try JSONEncoder().encode(ContentReport.comment("c9"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], ["kind": "comment", "commentId": "c9"])
    }

    func testTheSampleAppReportsLocally() async throws {
        SampleMode.set(true)
        let seen = PathLog(), bodies = BodyLog()
        try await ContentReporter.send(.chat("m1"), client: client(seen, bodies: bodies))
        XCTAssertEqual(seen.paths, [])
        XCTAssertEqual(ContentReporter.confirmation, "Reported (sample app).")
    }

    @MainActor
    func testBlocksAreKeptPerAccountOnThisDevice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "moderation-tests"))
        defaults.removePersistentDomain(forName: "moderation-tests")
        let blocks = BlockList(defaults: defaults)
        blocks.use(account: "Abby@example.edu")
        blocks.block(id: "otto", name: "Otto")
        blocks.block(id: "otto", name: "Otto")
        XCTAssertEqual(blocks.people.map(\.id), ["otto"])
        XCTAssertTrue(blocks.isBlocked("otto"))

        let again = BlockList(defaults: defaults)
        again.use(account: "abby@example.edu")
        XCTAssertTrue(again.isBlocked("otto"), "kept after relaunch")
        again.use(account: "sage@example.edu")
        XCTAssertFalse(again.isBlocked("otto"), "another account has its own list")
        again.use(account: "abby@example.edu")
        again.unblock("otto")
        XCTAssertTrue(again.people.isEmpty)
        again.use(account: nil)
        again.block(id: "kai", name: "Kai") // signed out: not saved anywhere
        XCTAssertNil(defaults.data(forKey: "blockedPeople."))
    }
}

/// Request bodies a stubbed URLSession saw (thread-safe).
final class BodyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Data] = []
    func add(_ body: Data) { lock.withLock { list.append(body) } }
    var last: Data { lock.withLock { list.last ?? Data() } }
}
