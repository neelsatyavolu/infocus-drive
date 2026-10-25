import Foundation
import WebKit

/// Calls to Portal APIs from native code: no shared cookie jar (each request
/// carries exactly the cookies it means to send).
enum PortalAPI {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private struct DataEnvelope<T: Decodable>: Decodable { let data: T }
    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let message: String }
        let error: Body
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(DataEnvelope<T>.self, from: data).data
    }

    /// The Portal's `{ error: { message } }`, if the body has one.
    static func errorMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
    }

    static func json(_ method: String, _ path: String, portal: URL, body: [String: String],
                     cookies: [HTTPCookie] = []) throws -> URLRequest {
        var request = URLRequest(url: portal.appendingPathComponent(path))
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}

/// Matching the web view's cookies to the Portal.
enum PortalCookies {
    static let cookieNameKey = "portalSessionCookie"

    /// The Portal session cookie's name (the token exchange says; this is its default).
    static var sessionCookieName: String {
        UserDefaults.standard.string(forKey: cookieNameKey) ?? "infocus_session"
    }

    /// Cookies a browser would send to `host`.
    static func matches(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.lowercased()
        let host = host.lowercased()
        if domain.hasPrefix(".") { return host == String(domain.dropFirst()) || host.hasSuffix(domain) }
        return host == domain
    }

    /// Anything stored for the Portal's site (its domain, parents or subdomains):
    /// what Sign out clears. `name` is a cookie domain or a data record's display name.
    static func belongsToPortal(_ name: String, portalHost: String) -> Bool {
        let name = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty, !portalHost.isEmpty else { return false }
        return name == portalHost || portalHost.hasSuffix("." + name) || name.hasSuffix("." + portalHost)
    }

    @MainActor
    static func forPortal(_ portal: URL) async -> [HTTPCookie] {
        guard let host = portal.host else { return [] }
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter { matches($0, host: host) && (!$0.isSecure || portal.scheme == "https") }
    }

    /// After a domain move: copies the Portal cookies saved for an old domain
    /// (the session among them) to the same names on the Portal's domain, so
    /// nobody signs in again. The session token isn't tied to a domain.
    /// Cookies the Portal's domain already has win; the old ones are removed.
    @MainActor
    static func adoptLegacy(portal: URL, legacyHosts: [String], now: Date = Date()) async {
        guard let host = portal.host?.lowercased(), !legacyHosts.isEmpty else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let all = await store.allCookies()
        let existing = Set(all.filter { belongsToPortal($0.domain, portalHost: host) }.map(\.name))
        for cookie in all {
            guard let domain = movedDomain(cookie.domain, to: host, from: legacyHosts) else { continue }
            // Moved once, then gone: a later Sign out can't be undone by copying it back.
            await store.deleteCookie(cookie)
            guard !existing.contains(cookie.name), cookie.expiresDate.map({ $0 > now }) ?? true,
                  var properties = cookie.properties else { continue }
            properties[.domain] = domain
            if let copy = HTTPCookie(properties: properties) { await store.setCookie(copy) }
        }
    }

    /// ".old.com" → ".new.com", "meet.old.com" → "meet.new.com"; nil if not on an old domain.
    static func movedDomain(_ domain: String, to host: String, from legacyHosts: [String]) -> String? {
        let dot = domain.hasPrefix(".") ? "." : ""
        let bare = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let legacy = legacyHosts.first(where: { bare == $0 || bare.hasSuffix("." + $0) }) else { return nil }
        return dot + String(bare.dropLast(legacy.count)) + host
    }

    /// The signed-in session's value, if there is one that hasn't expired.
    @MainActor
    static func session(_ portal: URL, now: Date = Date()) async -> String? {
        let name = sessionCookieName
        return await forPortal(portal)
            .first { $0.name == name && !$0.value.isEmpty && ($0.expiresDate.map { $0 > now } ?? true) }?
            .value
    }

    /// Sign out: every cookie and stored record for the Portal's site.
    @MainActor
    static func clear(portalHost: String) async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types,
                               for: records.filter { belongsToPortal($0.displayName, portalHost: portalHost) })
        for cookie in await store.httpCookieStore.allCookies()
        where belongsToPortal(cookie.domain, portalHost: portalHost) {
            await store.httpCookieStore.deleteCookie(cookie)
        }
    }
}
