import XCTest
@testable import InFocusPortal

/// The queue rules ported from `src/lib/publishing-queue.ts`.
final class PublishingQueueLogicTests: XCTestCase {
    private func payload() throws -> QueuePayload {
        try PublishingFixtures.decode(QueuePayload.self, PublishingFixtures.queueJSON)
    }

    func testDecodesTheQueue() throws {
        let queue = try payload()
        XCTAssertTrue(queue.canEdit)
        XCTAssertEqual(queue.upcomingShows.first?.date, "2026-10-07")
        XCTAssertEqual(queue.packages.count, 4)
        let custom = try XCTUnwrap(queue.packages.first { $0.custom })
        XCTAssertEqual(custom.youtubePublication?.status, "FAILED")
        XCTAssertNotNil(custom.youtubePublication?.lastError)
        XCTAssertEqual(queue.packages.first { $0.id == "row-sf" }?.youtubePublication?.videoId, "abcDEF12345")
    }

    func testLiveListKeepsUpcomingShowsAndLeavesPastOnesOut() throws {
        let sections = QueueLogic.liveSections(try payload())
        XCTAssertEqual(sections.map(\.date), ["2026-10-07", "2026-10-09", "2026-10-14", "2026-10-16"])
        XCTAssertEqual(sections[0].packages.map(\.id), ["row-gas", "row-yoga"])
        XCTAssertEqual(sections[2].packages, [])
        XCTAssertFalse(sections.flatMap(\.packages).contains { $0.id == "row-sf" })
    }

    func testPastShowsAreNewestFirst() throws {
        var queue = try payload()
        let older = QueuePackage(id: "row-old", cycleNumber: 1, groupTopic: "Older", headline: nil, custom: false,
                                 queuedForAirAt: nil, queuedForShowDate: "2026-09-02", youtubePublication: nil,
                                 assignedProducer: nil, members: [], thumbnailUrl: nil)
        queue = QueuePayload(canEdit: queue.canEdit, publishingConfigured: true, packages: queue.packages + [older],
                             today: queue.today, upcomingShows: queue.upcomingShows, candidates: nil)
        XCTAssertEqual(QueueLogic.pastSections(queue).map(\.date), ["2026-09-30", "2026-09-02"])
    }

    func testUndatedPackagesGetTheirOwnSection() throws {
        let queue = try payload()
        let undated = QueuePackage(id: "row-x", cycleNumber: 2, groupTopic: "X", headline: nil, custom: false,
                                   queuedForAirAt: nil, queuedForShowDate: nil, youtubePublication: nil,
                                   assignedProducer: nil, members: [], thumbnailUrl: nil)
        let sections = QueueLogic.liveSections(QueuePayload(canEdit: true, publishingConfigured: true,
                                                            packages: queue.packages + [undated], today: queue.today,
                                                            upcomingShows: queue.upcomingShows, candidates: nil))
        XCTAssertEqual(sections.last?.date, QueueLogic.unassigned)
        XCTAssertEqual(QueueLogic.showLabel(QueueLogic.unassigned), "No show yet")
    }

    func testTwoPackagesPerShowAtMost() throws {
        let packages = try payload().packages
        // October 7 already has two: a third can't go there, but either of the two can stay.
        XCTAssertFalse(QueueLogic.canPlace(on: "2026-10-07", in: packages, moving: "row-fair"))
        XCTAssertTrue(QueueLogic.canPlace(on: "2026-10-07", in: packages, moving: "row-gas"))
        XCTAssertTrue(QueueLogic.canPlace(on: "2026-10-09", in: packages, moving: "row-gas"))
        XCTAssertEqual(QueueLogic.occupied(on: "2026-10-07", in: packages, excluding: "row-gas"), 1)
    }

    func testPastMeansBeforeTodayAndNotUpcoming() {
        let upcoming = ["2026-10-07", "2026-10-09"]
        XCTAssertTrue(QueueLogic.isPast("2026-09-30", upcoming: upcoming, today: "2026-10-05"))
        XCTAssertFalse(QueueLogic.isPast("2026-10-07", upcoming: upcoming, today: "2026-10-05"))
        XCTAssertFalse(QueueLogic.isPast("2026-10-21", upcoming: upcoming, today: "2026-10-05"))
        XCTAssertFalse(QueueLogic.isPast(nil, upcoming: upcoming, today: "2026-10-05"))
    }

    func testSubtitles() {
        XCTAssertEqual(QueueLogic.subtitle(custom: false, cycleNumber: 2, members: ["Abby", nil, "Otto"]), "Cycle 2 · Abby, Otto")
        XCTAssertEqual(QueueLogic.subtitle(custom: false, cycleNumber: 3, members: []), "Cycle 3")
        XCTAssertEqual(QueueLogic.subtitle(custom: true, cycleNumber: 0, members: ["Sage"]), "Custom")
    }

    func testEmbedCodeOnlyForRealVideoIds() {
        XCTAssertEqual(QueueLogic.watchURL(videoId: "abcDEF12345")?.absoluteString, "https://www.youtube.com/watch?v=abcDEF12345")
        XCTAssertTrue(QueueLogic.embedCode(videoId: "abcDEF12345")?.contains("youtube.com/embed/abcDEF12345") == true)
        XCTAssertNil(QueueLogic.embedCode(videoId: "\"><script>"))
        XCTAssertNil(QueueLogic.watchURL(videoId: "short"))
    }
}

final class PublicationStatusTests: XCTestCase {
    func testPackageStatuses() {
        func pub(_ status: String) -> YoutubePublication {
            YoutubePublication(status: status, videoId: nil, publishedAt: nil, lastError: nil)
        }
        XCTAssertEqual(PublicationStatus.package(nil).label, "Pending")
        XCTAssertEqual(PublicationStatus.package(pub("PUBLISHED")).tone, .success)
        XCTAssertEqual(PublicationStatus.package(pub("FAILED")).tone, .danger)
        XCTAssertEqual(PublicationStatus.package(pub("UPLOADING")).label, "Uploading")
    }

    func testShowStatusesAndProgress() throws {
        let show = try PublishingFixtures.showPublication(date: "2026-10-07")
        XCTAssertEqual(PublicationStatus.show(show.publication).label, "Uploading")
        XCTAssertEqual(PublicationStatus.show(nil).label, "Not uploaded")
        XCTAssertEqual(PublicationStatus.percent(uploaded: show.publication?.uploadedBytes,
                                                 total: show.publication?.totalBytes), 50)
        XCTAssertNil(PublicationStatus.percent(uploaded: 10, total: 0))
        XCTAssertEqual(PublicationStatus.percent(uploaded: 200, total: 100), 100)
    }

    func testCustomTitles() {
        XCTAssertNil(CustomPackageUploader.cleanTitle("   "))
        XCTAssertEqual(CustomPackageUploader.cleanTitle("  Club Fair  "), "Club Fair")
        XCTAssertEqual(CustomPackageUploader.cleanTitle(String(repeating: "a", count: 200))?.count, 150)
    }
}

final class PublishingLinkTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    func testQueueLinksOpenNativeScreens() {
        XCTAssertEqual(DeepLink.resolve(URL(string: "https://portal.example.edu/publishing-queue")!, portal: portal),
                       DeepLinkMatch(tab: .more, route: .publishing(.home)))
        XCTAssertEqual(DeepLink.resolve(URL(string: "https://portal.example.edu/publishing-queue/row-gas")!, portal: portal),
                       DeepLinkMatch(tab: .more, route: .publishing(.package(rowId: "row-gas"))))
        XCTAssertNil(PublishingRoute.deepLink(["publishing-queue", "a", "b"], []))
        XCTAssertNil(PublishingRoute.deepLink(["groups"], []))
    }
}

/// The calls themselves, through the stubbed network.
final class PublishingServiceTests: XCTestCase {
    private func service() -> PublishingService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return PublishingService(client: PortalClient(portal: URL(string: "https://portal.example.edu")!,
                                                      session: URLSession(configuration: config), cookies: { [] }))
    }

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "InFocusStubSession")
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    func testLoadsTheQueueWithCandidates() async throws {
        StubProtocol.handler = { _ in (200, Data(PublishingFixtures.queueJSON.utf8)) }
        let queue = try await service().queue(candidates: true)
        XCTAssertEqual(queue.packages.count, 4)
        let url = try XCTUnwrap(StubProtocol.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/package-cycle/queue")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "1")
    }

    func testMovesAPackage() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"ok":true}}"#.utf8)) }
        try await service().update(QueueUpdate(rowId: "row-gas", queued: true, showDate: "2026-10-09"))
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["rowId"] as? String, "row-gas")
        XCTAssertEqual(body?["queued"] as? Bool, true)
        XCTAssertEqual(body?["showDate"] as? String, "2026-10-09")
    }

    func testShowsThePortalsReasonWhenAShowIsFull() async {
        StubProtocol.handler = { _ in (400, Data(#"{"error":{"message":"That show already has 2 packages."}}"#.utf8)) }
        do {
            try await service().update(QueueUpdate(rowId: "row-fair", queued: true, showDate: "2026-10-07"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That show already has 2 packages.")
        }
    }

    func testRemovesAManagerById() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"deleted":true}}"#.utf8)) }
        try await service().removeManager(userId: "u-juno")
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.query, "userId=u-juno")
    }

    @MainActor
    func testModelRefusesAThirdPackageBeforeAsking() async throws {
        StubProtocol.handler = { _ in (200, Data(PublishingFixtures.queueJSON.utf8)) }
        let model = PublishingModel()
        let service = service()
        await model.load(service)
        let fair = try XCTUnwrap(model.package("row-fair"))
        StubProtocol.lastRequest = nil
        let moved = await model.move(fair, to: "2026-10-07", service: service)
        XCTAssertFalse(moved)
        XCTAssertEqual(model.actionError, QueueLogic.showFullMessage)
        XCTAssertNil(StubProtocol.lastRequest)
    }
}
