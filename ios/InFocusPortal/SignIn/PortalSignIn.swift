import AuthenticationServices
import UIKit
import WebKit

/// Signs the app in through the browser (Google can't run inside an app's web
/// view): ASWebAuthenticationSession → `/app-sign-in` → Allow →
/// `infocus://signed-in?code=…` → code + verifier for a session → cookie in
/// the web view's store.
@MainActor
final class PortalSignIn: NSObject {
    static let shared = PortalSignIn()

    private var session: ASWebAuthenticationSession?

    var isBusy: Bool { session != nil }

    /// True once the Portal session cookie is set; false if the person cancelled.
    func signIn(portal: URL) async throws -> Bool {
        guard session == nil else { return false }
        let verifier = PKCE.random(bytes: 32)
        let state = PKCE.random(bytes: 16)
        var parts = URLComponents(url: portal.appendingPathComponent("app-sign-in"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = parts.url else { throw SignInError("Couldn't start sign-in.") }

        let callback = try await browserCallback(url)
        guard let callback else { return false }
        switch SignInCallback.parse(callback, state: state) {
        case .cancelled:
            return false
        case .invalid:
            throw SignInError("Sign-in didn't match this request. Try again.")
        case .code(let code):
            let token = try await exchange(code: code, verifier: verifier, portal: portal)
            guard let cookie = token.httpCookie(portal: portal) else { throw SignInError("The Portal sent a bad session.") }
            await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
            UserDefaults.standard.set(token.cookie.name, forKey: PortalCookies.cookieNameKey)
            return true
        }
    }

    /// The `infocus://` URL the browser came back with; nil when cancelled.
    private func browserCallback(_ url: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: SignInCallback.scheme) { [weak self] callback, error in
                Task { @MainActor in self?.session = nil }
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: SignInError(error.localizedDescription))
                    }
                    return
                }
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false // reuse Safari's Google sign-in
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: SignInError("Couldn't open the sign-in window. Try again."))
            }
        }
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
}

extension PortalSignIn: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { UIApplication.shared.keyWindow ?? ASPresentationAnchor() }
    }
}

extension UIApplication {
    /// The foreground window, for presenting sheets from non-view code.
    var keyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { $0.activationState == .foregroundActive && $1.activationState != .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
    }
}
