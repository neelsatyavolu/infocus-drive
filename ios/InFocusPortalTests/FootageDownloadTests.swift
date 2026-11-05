import XCTest
@testable import InFocusPortal

/// A-roll/B-roll footage downloads: one clip, a selection or every clip as a zip (placeholder people only).
@MainActor
final class FootageDownloadTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private var stubSession: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func client() -> PortalClient {
        let cookie = HTTPCookie(properties: [.name: "infocus_session", .value: "token-123",
                                             .domain: "portal.example.edu", .path: "/"])!
        return PortalClient(portal: portal, session: stubSession, cookies: { [cookie] })
    }

    private func clip(_ id: String, ready: Bool = true) -> StageMedia {
        StageMedia(id: id, title: "Interview \(id)", rollKind: "a-roll", projectId: "p1", versionId: "v-\(id)", versionNumber: 1,
                   status: ready ? "READY" : "PROCESSING", approvalStatus: nil, approvedInStage: nil, thumbnailUrl: nil,
                   playbackUrl: nil, commentCount: 0, isNew: nil)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    // MARK: Footage

    func testDownloadAllAsksForOneClipOrTheWholeZipAndSkipsUnreadyClips() {
        XCTAssertEqual(FootageFile.path(rowId: "r1"), "api/package-cycle/a-roll/r1/download")
        XCTAssertEqual(FootageFile.query(["m1", "m2"]).map(\.value), ["m1", "m2"])
        XCTAssertEqual(FootageFile.query(["m1"]).map(\.name), ["id"])
        XCTAssertEqual(FootageFile.allIDs([clip("m1"), clip("m2", ready: false)]), ["m1"], "a lone ready clip downloads as itself")
        XCTAssertEqual(FootageFile.allIDs([clip("m1"), clip("m2")]), [], "no ids means every ready clip as a zip")
        XCTAssertEqual(FootageFile.readyIDs([clip("m1", ready: false), clip("m2")]), ["m2"])
    }

    func testFileNamesComeFromTheServerElseTheClip() {
        XCTAssertEqual(FootageFile.filename(suggested: "Robotics - Cycle 3 footage.zip", fallback: "x", mimeType: "application/zip"),
                       "Robotics - Cycle 3 footage.zip")
        XCTAssertEqual(FootageFile.filename(suggested: "../../evil.mov", fallback: "x", mimeType: nil), "evil.mov")
        XCTAssertEqual(FootageFile.filename(suggested: "Unknown", fallback: "Interview", mimeType: "video/quicktime"), "Interview.mov")
        XCTAssertEqual(FootageFile.filename(suggested: "download", fallback: "Interview", mimeType: nil), "Interview.mp4")
        XCTAssertEqual(FootageFile.filename(suggested: nil, fallback: "Club Fair footage.zip", mimeType: nil), "Club Fair footage.zip")
    }

    func testSelectionKeepsOnlyReadyClipsAndTitlesCountThem() {
        let downloader = FootageDownloader(onUnauthorized: {})
        downloader.selecting = true
        downloader.toggle("m1")
        downloader.toggle("m2")
        downloader.toggle("gone")
        XCTAssertEqual(downloader.picked(in: [clip("m1"), clip("m2", ready: false)]), ["m1"])
        downloader.toggle("m1")
        XCTAssertEqual(downloader.picked(in: [clip("m1")]), [])
        downloader.stopSelecting()
        XCTAssertFalse(downloader.selecting)
        XCTAssertTrue(downloader.selected.isEmpty)
        XCTAssertEqual(FootageDownloader.selectionTitle(0), "Download")
        XCTAssertEqual(FootageDownloader.selectionTitle(1), "Download 1 clip")
        XCTAssertEqual(FootageDownloader.selectionTitle(3), "Download 3 clips")
        XCTAssertEqual(FootageDownloader.progressText(received: 0, total: nil), "Zero KB")
        XCTAssertTrue(FootageDownloader.progressText(received: 1_000_000, total: 2_000_000).contains(" of "))
    }

    func testStreamsTheZipToAFileSignedInThenShares() async throws {
        StubProtocol.handler = { _ in (200, Data("PK zip bytes".utf8)) }
        let downloader = FootageDownloader(onUnauthorized: {})
        downloader.selecting = true
        downloader.toggle("m1")
        let shared = expectation(description: "shared")
        var file: URL?
        downloader.start(rowId: "r1", ids: ["m1", "m2"], label: "2 clips", fallbackName: "Club Fair footage.zip",
                         client: client(), session: stubSession) { url in
            file = url
            shared.fulfill()
        }
        XCTAssertTrue(downloader.isBusy)
        await fulfillment(of: [shared], timeout: 5)

        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/package-cycle/a-roll/r1/download")
        XCTAssertEqual(request.url?.query, "id=m1&id=m2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "infocus_session=token-123")
        let saved = try XCTUnwrap(file)
        XCTAssertFalse(saved.pathExtension.isEmpty, "named by the server (the stub sends none, so it's sniffed)")
        XCTAssertTrue(saved.path.hasPrefix(FootageFile.folder.path))
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "PK zip bytes")
        XCTAssertEqual(downloader.phase, .idle)
        XCTAssertFalse(downloader.selecting, "a started download leaves Select mode, as on the web")
    }

    func testRefusalShowsThePortalsWords() async throws {
        StubProtocol.handler = { _ in
            (413, Data(#"{"error":{"message":"That is too much footage for one zip (40 GB max)."}}"#.utf8))
        }
        let request = await client().request("GET", FootageFile.path(rowId: "r1"))
        do {
            _ = try await FootageFile.download(request, fallbackName: "x.zip", session: stubSession) { _, _ in }
            XCTFail("expected a refusal")
        } catch let error as PortalError {
            XCTAssertEqual(error.localizedDescription, "That is too much footage for one zip (40 GB max).")
        }
    }

    func testSignedOutSessionGoesBackToSignIn() async {
        StubProtocol.handler = { _ in (401, Data()) }
        let signedOut = expectation(description: "signed out")
        let downloader = FootageDownloader(onUnauthorized: { signedOut.fulfill() })
        downloader.start(rowId: "r1", ids: [], label: "All footage", fallbackName: "x.zip", client: client(),
                         session: stubSession) { _ in XCTFail("nothing to share") }
        await fulfillment(of: [signedOut], timeout: 5)
        XCTAssertEqual(downloader.phase, .idle)
    }
}
