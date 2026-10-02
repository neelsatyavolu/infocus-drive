import CryptoKit
import Foundation
import Security

/// PKCE (RFC 7636, S256): the app keeps the verifier, the browser only sees
/// the challenge, so a sign-in code is useless without this copy of the app.
enum PKCE {
    static func random(bytes count: Int) -> String {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "no secure random bytes")
        return base64URL(data)
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// `infocus://signed-in?code=…&state=…` or `…?error=cancelled&state=…`.
enum SignInCallback: Equatable {
    case code(String), cancelled, invalid

    static let scheme = "infocus"

    static func parse(_ url: URL, state: String) -> SignInCallback {
        guard url.scheme == scheme, url.host == "signed-in",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return .invalid }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { return .invalid }
        if value("error") != nil { return .cancelled }
        guard let code = value("code"), !code.isEmpty else { return .invalid }
        return .code(code)
    }
}

/// `POST /api/auth/app/token` → `{ data: { token, maxAgeSeconds, cookie } }`.
struct AppSessionToken: Decodable, Equatable {
    struct Cookie: Decodable, Equatable {
        let name: String
        let domain: String?
        let path: String
    }

    let token: String
    let maxAgeSeconds: Int
    let cookie: Cookie

    /// The Portal session cookie, as the website would have set it.
    func httpCookie(portal: URL, now: Date = Date()) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: token,
            .domain: cookie.domain ?? portal.host ?? "",
            .path: cookie.path,
            .expires: now.addingTimeInterval(TimeInterval(maxAgeSeconds)),
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue,
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]
        if portal.scheme == "https" { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}

struct SignInError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
