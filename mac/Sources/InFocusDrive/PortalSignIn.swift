import AppKit
import AuthenticationServices
import CryptoKit
import WebKit

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

    static func parse(_ url: URL, state: String) -> SignInCallback {
        guard url.scheme == "infocus", url.host == "signed-in",
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

    static func forPortal(_ portal: URL) async -> [HTTPCookie] {
        guard let host = portal.host else { return [] }
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter { matches($0, host: host) && (!$0.isSecure || portal.scheme == "https") }
    }
}

struct SignInError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Signs the Portal window in through the browser (Google can't run inside an
/// app's web view): ASWebAuthenticationSession → `/app-sign-in` → Allow →
/// `infocus://signed-in?code=…` → code + verifier for a session → cookie.
/// Then Drive's own approval, if Drive isn't signed in yet.
@MainActor
final class PortalSignIn: NSObject, ObservableObject {
    static let shared = PortalSignIn()

    @Published private(set) var busy = false
    private var session: ASWebAuthenticationSession?

    static let cookieNameKey = "portalSessionCookie"
    static var sessionCookieName: String {
        UserDefaults.standard.string(forKey: cookieNameKey) ?? "infocus_session"
    }

    func signIn(drive: DriveController, returnTo: URL? = nil, webView: WKWebView? = nil) {
        guard !busy, let portal = AppConfig.shared.portalURL else { return }
        let verifier = PKCE.random(bytes: 32)
        let state = PKCE.random(bytes: 16)
        var parts = URLComponents(url: portal.appendingPathComponent("app-sign-in"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = parts.url else { return }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "infocus") { [weak self] callback, error in
            Task { @MainActor in
                await self?.finish(callback: callback, error: error, verifier: verifier, state: state,
                                   portal: portal, drive: drive, returnTo: returnTo, webView: webView)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false // reuse the browser's Google sign-in
        self.session = session
        busy = true
        if !session.start() {
            busy = false
            self.session = nil
            show("Couldn't open the sign-in window. Try again.")
        }
    }

    private func finish(callback: URL?, error: Error?, verifier: String, state: String, portal: URL,
                        drive: DriveController, returnTo: URL?, webView: WKWebView?) async {
        session = nil
        defer { busy = false }
        if let error {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { show(error.localizedDescription) }
            return
        }
        guard let callback else { return show("Sign-in didn't finish. Try again.") }
        switch SignInCallback.parse(callback, state: state) {
        case .cancelled:
            return
        case .invalid:
            return show("Sign-in didn't match this request. Try again.")
        case .code(let code):
            do {
                let token = try await exchange(code: code, verifier: verifier, portal: portal)
                guard let cookie = token.httpCookie(portal: portal) else { throw SignInError("The Portal sent a bad session.") }
                await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
                UserDefaults.standard.set(token.cookie.name, forKey: Self.cookieNameKey)
            } catch {
                return show(error.localizedDescription)
            }
        }
        reload(webView, portal: portal, returnTo: returnTo)
        await PushRegistrar.shared.afterSignIn()
        await drive.refreshAccount()
        if drive.hasServer, drive.account == .signedOut { drive.signIn() }
    }

    private func exchange(code: String, verifier: String, portal: URL) async throws -> AppSessionToken {
        let request = try PortalAPI.json("POST", "api/auth/app/token", portal: portal,
                                         body: ["code": code, "verifier": verifier])
        let (data, response) = try await PortalAPI.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SignInError(PortalAPI.errorMessage(data) ?? "Sign-in failed (\(status)). Try again.")
        }
        return try PortalAPI.decode(AppSessionToken.self, from: data)
    }

    private func reload(_ webView: WKWebView?, portal: URL, returnTo: URL?) {
        if let webView {
            if let returnTo {
                webView.load(URLRequest(url: returnTo))
            } else if webView.url?.path == "/sign-in" || webView.url == nil {
                webView.load(URLRequest(url: portal))
            } else {
                webView.reload()
            }
        }
        Windows.shared.reloadPortals(except: webView)
    }

    /// Sign out of everything: this Mac's push device, the Portal session and
    /// other site data in the app, and Drive.
    func signOut(drive: DriveController) async {
        await PushRegistrar.shared.unregister()
        if let host = AppConfig.shared.portalHost {
            let store = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let records = await store.dataRecords(ofTypes: types)
            await store.removeData(ofTypes: types,
                                   for: records.filter { PortalCookies.belongsToPortal($0.displayName, portalHost: host) })
            for cookie in await store.httpCookieStore.allCookies()
            where PortalCookies.belongsToPortal(cookie.domain, portalHost: host) {
                await store.httpCookieStore.deleteCookie(cookie)
            }
        }
        if drive.hasServer { drive.signOut() }
        Windows.shared.reloadPortals(except: nil)
    }

    private func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't sign in to InFocus"
        alert.informativeText = message
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension PortalSignIn: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
    }
}
