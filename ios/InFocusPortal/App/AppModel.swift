import SwiftUI
import UserNotifications

/// The app's state: welcome (signed out), the Portal's email sign-in page, or
/// the native tabs once signed in. Owns the shared stores the tabs read.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable { case launching, welcome, emailSignIn, signedIn, unconfigured }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var signingIn = false
    @Published var signInError: String?
    @Published var offeringNotifications = false
    /// A short note at the bottom of the screen ("Sample app: changes aren't saved.").
    @Published private(set) var sampleNotice: String?
    private var sampleNoticeTask: Task<Void, Never>?

    let config: AppConfig
    let client: PortalClient
    let session = SessionStore()
    let router = Router()
    let badges = BadgeCenter()
    let preferences = Preferences()
    /// The web view for the Portal's own email-code sign-in page.
    let signInWeb: PortalWebController?

    /// A page to open once signed in (a notification, or the page that asked for sign-in).
    private var pendingPage: URL?

    static let notificationsOfferedKey = "notificationsOffered"

    init(config: AppConfig = .shared) {
        self.config = config
        let portal = config.portalURL ?? URL(string: "https://portal.invalid")!
        client = .live(portal: portal)
        router.portal = config.portalURL
        signInWeb = config.portalURL.map { PortalWebController(portal: $0) }
        signInWeb?.delegate = self
        router.onRefused = { [weak self] in
            self?.showSampleNotice("That page is on the Portal website, not in the sample app.")
        }
    }

    func launch() async {
        guard let portal = config.portalURL else {
            phase = .unconfigured
            return
        }
        #if DEBUG
        // Screens without a Portal: `-InFocusStubSession student -InFocusOpen settings`.
        let defaults = UserDefaults.standard
        if let kind = defaults.string(forKey: "InFocusStubSession") {
            session.useStub(.stub(kind))
            router.sampleOnly = session.user?.sampleOnly ?? false
            phase = .signedIn
            switch defaults.string(forKey: "InFocusOpen") {
            case "more"?: router.select(.more)
            case "portal-pages"?: router.select(.more); router.push(.more(.portalPages))
            case let path?: router.open(portal.appendingPathComponent(path))
            case nil: break
            }
            return
        }
        #endif
        PushRegistrar.shared.start()
        if await PortalCookies.session(portal) != nil {
            await enterApp()
        } else {
            phase = .welcome
        }
    }

    /// A notification tap: show its page now, or right after sign-in.
    func open(_ url: URL) {
        if phase == .signedIn {
            router.open(url)
        } else {
            pendingPage = url
        }
    }

    private func enterApp() async {
        phase = .signedIn
        await session.load(using: client)
        let sampleOnly = session.user?.sampleOnly ?? false
        SampleMode.set(sampleOnly)
        router.sampleOnly = sampleOnly
        if let page = takePendingPage() { router.open(page) }
        if !sampleOnly { await badges.refresh(using: client) }
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
                await enterApp()
                await didSignIn()
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    /// Email-code sign-in runs on the Portal's own /sign-in page.
    func signInWithEmail() {
        guard let portal = config.portalURL, let signInWeb else { return }
        var parts = URLComponents(url: portal.appendingPathComponent("sign-in"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "returnTo", value: "/dashboard")]
        phase = .emailSignIn
        if let url = parts.url { signInWeb.load(url) }
    }

    /// Back to the welcome screen from the email sign-in page.
    func backToWelcome() {
        phase = .welcome
    }

    /// Sign out natively, so the push device is removed while the session still exists.
    func signOut() {
        guard let host = config.portalHost else { return }
        Task {
            await PushRegistrar.shared.unregister()
            await PortalCookies.clear(portalHost: host)
            resetSignedInState()
            signInWeb?.load(URL(string: "about:blank")!)
            phase = .welcome
        }
    }

    /// A Portal call answered 401: the session expired or was signed out elsewhere.
    func sessionEnded() {
        guard phase == .signedIn else { return }
        resetSignedInState()
        signInError = "Your Portal session ended. Sign in again."
        phase = .welcome
    }

    private func resetSignedInState() {
        SampleMode.set(false)
        session.clear()
        router.reset()
        badges.clear()
        pendingPage = nil
    }

    private func didSignIn() async {
        await PushRegistrar.shared.sync(force: true)
        if !UserDefaults.standard.bool(forKey: Self.notificationsOfferedKey),
           await PushRegistrar.shared.shouldOfferPermission() {
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

    // MARK: Sample app

    /// Shows `message` briefly at the bottom of the screen (the App Review sample app).
    func showSampleNotice(_ message: String = SampleMode.notice) {
        sampleNoticeTask?.cancel()
        sampleNotice = message
        sampleNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.sampleNotice = nil
        }
    }

    /// Opening the app clears the icon's badge and refreshes the tab badges.
    func becameActive() {
        UNUserNotificationCenter.current().setBadgeCount(0)
        guard phase == .signedIn, session.user?.sampleOnly != true else { return }
        Task { await badges.refresh(using: client) }
    }
}

extension AppModel: PortalWebDelegate {
    func portalWebNeedsSignIn(returnTo: URL?) {
        signInWithSchoolAccount(returnTo: returnTo)
    }

    func portalWebRequestedSignOut() {
        signOut()
    }

    /// Every web view reports finished pages: an email-code sign-in completes
    /// here, and a session that ended inside a page sends the app to sign-in.
    func portalWebDidFinish(_ url: URL?) {
        guard let portal = config.portalURL, let host = config.portalHost else { return }
        Task {
            if await PortalCookies.session(portal) != nil {
                if phase == .emailSignIn {
                    await enterApp()
                    await didSignIn()
                }
                PushRegistrar.shared.syncIfNeeded()
            } else if phase == .signedIn, PortalNavigation.isSignInPage(url, portalHost: host) {
                sessionEnded()
                pendingPage = url.flatMap { PortalNavigation.returnTo(from: $0, portal: portal) }
            }
        }
    }
}
