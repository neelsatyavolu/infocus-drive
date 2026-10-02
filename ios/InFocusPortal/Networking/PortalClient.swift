import Foundation
import SwiftUI

/// Native calls to Portal APIs as the signed-in person: the same session
/// cookie the web view uses, attached by hand to each request (no shared
/// cookie jar). Decodes `{ data }`, turns `{ error: { message } }` into
/// `PortalError`, and reports a 401 so the app can go back to sign-in.
///
///     let groups: [GroupTile] = try await client.get("api/groups")
///     let saved: Comment = try await client.post("api/comments", body: NewComment(text: "Nice"))
///     try await client.delete("api/comments/\(id)")
struct PortalClient: Sendable {
    typealias CookieSource = @Sendable () async -> [HTTPCookie]

    let portal: URL
    private let session: URLSession
    private let cookies: CookieSource
    private let onUnauthorized: @Sendable () async -> Void

    init(portal: URL, session: URLSession = PortalClient.urlSession, cookies: @escaping CookieSource,
         onUnauthorized: @escaping @Sendable () async -> Void = {}) {
        self.portal = portal
        self.session = session
        self.cookies = cookies
        self.onUnauthorized = onUnauthorized
    }

    /// The live client: the web view's cookies; a 401 sends the app back to sign-in.
    static func live(portal: URL) -> PortalClient {
        PortalClient(portal: portal,
                     cookies: { await PortalCookies.forPortal(portal) },
                     onUnauthorized: { await AppModel.shared.sessionEnded() })
    }

    static let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Mobile Safari's, plus the token the Portal looks for (`/InFocusiOSApp/i`).
    static var userAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + PortalWebController.userAgentSuffix
    }

    // MARK: JSON helpers

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        try decode(type, from: try await send("GET", path, query: query))
    }

    func post<T: Decodable>(_ path: String, body: some Encodable, as type: T.Type = T.self) async throws -> T {
        try decode(type, from: try await send("POST", path, body: try PortalJSON.encoder().encode(body)))
    }

    func patch<T: Decodable>(_ path: String, body: some Encodable, as type: T.Type = T.self) async throws -> T {
        try decode(type, from: try await send("PATCH", path, body: try PortalJSON.encoder().encode(body)))
    }

    func put<T: Decodable>(_ path: String, body: some Encodable, as type: T.Type = T.self) async throws -> T {
        try decode(type, from: try await send("PUT", path, body: try PortalJSON.encoder().encode(body)))
    }

    @discardableResult
    func delete(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await send("DELETE", path, query: query)
    }

    /// DELETE with a JSON body (some Portal routes take `{ id }`).
    @discardableResult
    func delete(_ path: String, body: some Encodable) async throws -> Data {
        try await send("DELETE", path, body: try PortalJSON.encoder().encode(body))
    }

    /// POST whose answer isn't needed.
    func post(_ path: String, body: some Encodable) async throws {
        _ = try await send("POST", path, body: try PortalJSON.encoder().encode(body))
    }

    // MARK: Requests

    /// `path` is relative to the Portal ("api/groups", no leading slash needed).
    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var parts = URLComponents(url: portal.appendingPathComponent(trimmed), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                 contentType: String = "application/json") async -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (field, value) in HTTPCookie.requestHeaderFields(with: await cookies()) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// Sends one request and returns the body of a 2xx answer.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        try await perform(await request(method, path, query: query, body: body))
    }

    func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PortalError.from(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = PortalError.from(status: status, message: PortalJSON.errorMessage(data))
            if error == .unauthorized { await onUnauthorized() }
            throw error
        }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: data).data
        } catch {
            throw PortalError.decoding(String(describing: error))
        }
    }
}

// MARK: Environment

private struct PortalClientKey: EnvironmentKey {
    static let defaultValue = PortalClient(portal: AppConfig.shared.portalURL ?? URL(string: "https://portal.invalid")!,
                                           cookies: { [] })
}

extension EnvironmentValues {
    /// The signed-in Portal client: `@Environment(\.portalClient) private var client`.
    var portalClient: PortalClient {
        get { self[PortalClientKey.self] }
        set { self[PortalClientKey.self] = newValue }
    }
}
