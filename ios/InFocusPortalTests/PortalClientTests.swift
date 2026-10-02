import XCTest
@testable import InFocusPortal

/// Answers requests from a closure instead of the network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            request.httpBody = data
        }
        Self.lastRequest = request
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PortalClientTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func client(unauthorized: @escaping @Sendable () async -> Void = {}) -> PortalClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let cookie = HTTPCookie(properties: [.name: "infocus_session", .value: "token-123",
                                             .domain: "portal.example.edu", .path: "/"])!
        return PortalClient(portal: portal, session: URLSession(configuration: config),
                            cookies: { [cookie] }, onUnauthorized: unauthorized)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    struct Tile: Decodable, Equatable { let id: String; let updatedAt: Date }

    func testDecodesEnvelopeAndDatesAndSendsSession() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"data":[{"id":"a","updatedAt":"2026-10-02T19:32:36.224Z"}]}"#.utf8))
        }
        let tiles: [Tile] = try await client().get("api/groups", query: [URLQueryItem(name: "cycle", value: "2")])
        XCTAssertEqual(tiles.map(\.id), ["a"])
        XCTAssertEqual(tiles[0].updatedAt.timeIntervalSince1970, 1_790_969_556.224, accuracy: 0.001)
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://portal.example.edu/api/groups?cycle=2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "infocus_session=token-123")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("InFocusiOSApp/") == true)
    }

    func testPostsJSONBody() async throws {
        struct NewComment: Encodable { let text: String }
        StubProtocol.handler = { _ in (201, Data(#"{"data":{"ok":true}}"#.utf8)) }
        try await client().post("api/comments", body: NewComment(text: "Nice"))
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(data: request.httpBody ?? Data(), encoding: .utf8), #"{"text":"Nice"}"#)
    }

    func testErrorsCarryThePortalMessage() async {
        StubProtocol.handler = { _ in (400, Data(#"{"error":{"message":"Pick a cycle first."}}"#.utf8)) }
        do {
            let _: PortalJSON.Empty = try await client().get("api/groups")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PortalError, .server(status: 400, message: "Pick a cycle first."))
            XCTAssertEqual(error.localizedDescription, "Pick a cycle first.")
        }
    }

    func testUnauthorizedEndsTheSession() async {
        let ended = expectation(description: "session ended")
        StubProtocol.handler = { _ in (401, Data(#"{"error":{"message":"Unauthorized"}}"#.utf8)) }
        do {
            let _: PortalJSON.Empty = try await client(unauthorized: { ended.fulfill() }).get("api/profile")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PortalError, .unauthorized)
        }
        await fulfillment(of: [ended], timeout: 1)
    }

    func testStatusMapping() {
        XCTAssertEqual(PortalError.from(status: 403, message: "Forbidden").errorDescription, "You don't have access to this.")
        XCTAssertEqual(PortalError.from(status: 404, message: nil), .notFound)
        XCTAssertEqual(PortalError.from(status: 503, message: "x").errorDescription, "The Portal isn't responding. Try again in a minute.")
        XCTAssertEqual(PortalError.from(URLError(.notConnectedToInternet)), .offline)
    }

    func testDateFormats() {
        XCTAssertNotNil(PortalJSON.date(from: "2026-10-02T19:32:36Z"))
        XCTAssertNotNil(PortalJSON.date(from: "2026-10-02T19:32:36.224Z"))
        XCTAssertEqual(PortalJSON.date(from: "2026-10-02")?.timeIntervalSince1970, 1_790_899_200)
        XCTAssertNil(PortalJSON.date(from: "yesterday"))
    }

    func testURLsAreRelativeToThePortal() {
        XCTAssertEqual(client().url("/api/x").absoluteString, "https://portal.example.edu/api/x")
        XCTAssertEqual(client().url("api/x").absoluteString, "https://portal.example.edu/api/x")
    }
}
