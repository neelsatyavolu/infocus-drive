import SwiftUI
import UserNotifications

/// The app's state: welcome (signed out) or the Portal, plus the sign-in
/// hand-off, sign-out and the one-time notifications offer.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable { case launching, welcome, portal, unconfigured }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var signingIn = false
    @Published var signInError: String?
    @Published var offeringNotifications = false

    let config: AppConfig
    let web: PortalWebController?

    /// A page to open once signed in (a notification, or the page that asked for sign-in).
    private var pendingPage: URL?
    /// The last session state seen, to notice sign-ins that happen in the web view.
    private var signedIn = false
    /// The person chose the Portal's own email sign-in, so its /sign-in page stays.
    @Published private(set) var usingEmailSignIn = false

    static let notificationsOfferedKey = "notificationsOffered"

    init(config: AppConfig = .shared) {
        self.config = config
        web = config.portalURL.map { PortalWebController(portal: $0) }
        web?.delegate = self
    }

    func launch() async {
        guard let portal = config.portalURL, let web, let home = config.homeURL else {
            phase = .unconfigured
            return
        }
        PushRegistrar.shared.start()
        if await PortalCookies.session(portal) != nil {
            signedIn = true
            phase = .portal
            web.load(takePendingPage() ?? home)
        } else {
            phase = .welcome
        }
    }

    /// A notification tap: show its page now, or right after sign-in.
    func open(_ url: URL) {
        if phase == .portal, let web {
            web.load(url)
        } else {
            pendingPage = url
        }
    }

    // MARK: Sign in and out

    func signInWithSchoolAccount(returnTo: URL? = nil) {
        guard let portal = config.portalURL, !signingIn else { return }
        if let returnTo { pendingPage = returnTo }
        signingIn = true
        signInError = nil
        Task {
            defer { signingIn = false }
            do {
                guard try await PortalSignIn.shared.signIn(portal: portal) else { return } // cancelled
                usingEmailSignIn = false
                phase = .portal
                if let page = takePendingPage() ?? config.homeURL { web?.load(page) }
                await didSignIn()
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    /// Email-code sign-in runs on the Portal's own /sign-in page.
    func signInWithEmail() {
        guard let portal = config.portalURL, let web else { return }
        usingEmailSignIn = true
        var parts = URLComponents(url: portal.appendingPathComponent("sign-in"), resolvingAgainstBaseURL: false)!
        let target = pendingPage.flatMap { $0.host == portal.host ? $0.path : nil } ?? "/dashboard"
        parts.queryItems = [URLQueryItem(name: "returnTo", value: target)]
        pendingPage = nil
        phase = .portal
        if let url = parts.url { web.load(url) }
    }

    /// Back to the welcome screen from the email sign-in page.
    func backToWelcome() {
        usingEmailSignIn = false
        phase = .welcome
    }

    /// The Portal's Sign out button, run natively so the push device is
    /// removed while the session still exists.
    func signOut() {
        guard let host = config.portalHost else { return }
        Task {
            await PushRegistrar.shared.unregister()
            await PortalCookies.clear(portalHost: host)
            signedIn = false
            usingEmailSignIn = false
            pendingPage = nil
            web?.load(URL(string: "about:blank")!)
            phase = .welcome
        }
    }

    private func didSignIn() async {
        signedIn = true
        await PushRegistrar.shared.sync(force: true)
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.notificationsOfferedKey), await PushRegistrar.shared.shouldOfferPermission() {
            offeringNotifications = true
        }
    }

    private func takePendingPage() -> URL? {
        defer { pendingPage = nil }
        return pendingPage
    }

    // MARK: Notifications offer

    func answerNotificationsOffer(turnOn: Bool) {
        UserDefaults.standard.set(true, forKey: Self.notificationsOfferedKey)
        offeringNotifications = false
        guard turnOn else { return }
        Task { _ = await PushRegistrar.shared.requestPermission() }
    }

    /// Opening the app clears the icon's badge.
    func becameActive() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}

extension AppModel: PortalWebDelegate {
    func portalWebNeedsSignIn(returnTo: URL?) {
        signInWithSchoolAccount(returnTo: returnTo)
    }

    func portalWebRequestedSignOut() {
        signOut()
    }

    func portalWebDidFinish(_ url: URL?) {
        guard let portal = config.portalURL, let host = config.portalHost else { return }
        Task {
            if await PortalCookies.session(portal) != nil {
                if !signedIn {
                    usingEmailSignIn = false
                    await didSignIn() // email code, or a session from an earlier version
                }
                PushRegistrar.shared.syncIfNeeded()
            } else {
                signedIn = false
                // The session ended (expired, or signed out elsewhere): sign in natively.
                if PortalNavigation.isSignInPage(url, portalHost: host), !usingEmailSignIn {
                    pendingPage = url.flatMap { PortalNavigation.returnTo(from: $0, portal: portal) }
                    phase = .welcome
                }
            }
        }
    }
}
