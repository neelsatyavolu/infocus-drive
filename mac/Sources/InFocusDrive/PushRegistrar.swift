import AppKit
import CryptoKit
import UserNotifications
import WebKit

/// Mac notifications for Portal emails: asks macOS for permission, gets this
/// Mac's APNs token and registers it with the Portal under the signed-in
/// account (`POST /api/push/native-device`). Builds without the push
/// entitlement (ad-hoc, development) just never get a token.
@MainActor
final class PushRegistrar: ObservableObject {
    static let shared = PushRegistrar()

    /// Lowercase hex APNs token, once macOS hands it over.
    @Published private(set) var deviceToken: String?
    /// Fingerprint of the token + Portal session last registered (nil: not registered).
    @Published private(set) var registeredFor: String?
    private var syncing = false

    static var environment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    nonisolated static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    private var center: UNUserNotificationCenter { .current() }

    /// At launch: Apple wants registration every launch once notifications are allowed.
    func start() async {
        let settings = await center.notificationSettings()
        if Self.allowed(settings.authorizationStatus) { NSApp.registerForRemoteNotifications() }
    }

    func didRegister(_ token: Data) {
        deviceToken = Self.hex(token)
        Task { await sync(force: true) }
    }

    func didFail(_ error: Error) {
        NSLog("InFocus: Mac notifications unavailable in this build: %@", error.localizedDescription)
    }

    /// Settings → Turn on, and the first sign-in.
    func requestPermission() async -> Status {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            NSLog("InFocus: notification permission request failed: %@", error.localizedDescription)
        }
        if Self.allowed(await center.notificationSettings().authorizationStatus) {
            NSApp.registerForRemoteNotifications()
        }
        return await status()
    }

    /// Right after a Portal sign-in: ask once, then register for this account.
    func afterSignIn() async {
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = await requestPermission()
        }
        await sync(force: true)
    }

    /// After each Portal page load: registers when the session changed.
    func syncIfNeeded() {
        Task { await sync(force: false) }
    }

    func sync(force: Bool) async {
        guard let token = deviceToken, let portal = AppConfig.shared.portalURL, !syncing else { return }
        let cookies = await PortalCookies.forPortal(portal)
        guard let session = cookies.first(where: { $0.name == PortalSignIn.sessionCookieName })?.value else {
            registeredFor = nil
            return
        }
        let key = Self.fingerprint(token + "\n" + session)
        if !force, registeredFor == key { return }
        syncing = true
        defer { syncing = false }
        let ok = await send("POST", body: [
            "token": token, "environment": Self.environment, "appVersion": DriveController.appVersion,
        ], cookies: cookies, portal: portal)
        registeredFor = ok ? key : nil
    }

    /// Sign out: this Mac stops getting the account's notifications.
    func unregister() async {
        defer { registeredFor = nil }
        guard let token = deviceToken, let portal = AppConfig.shared.portalURL else { return }
        let cookies = await PortalCookies.forPortal(portal)
        _ = await send("DELETE", body: ["token": token], cookies: cookies, portal: portal)
    }

    private func send(_ method: String, body: [String: String], cookies: [HTTPCookie], portal: URL) async -> Bool {
        do {
            let request = try PortalAPI.json(method, "api/push/native-device", portal: portal, body: body, cookies: cookies)
            let (data, response) = try await PortalAPI.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                NSLog("InFocus: push device %@ failed (%d): %@", method, status, PortalAPI.errorMessage(data) ?? "")
                return false
            }
            return true
        } catch {
            NSLog("InFocus: push device %@ failed: %@", method, error.localizedDescription)
            return false
        }
    }

    // MARK: Settings bridge

    struct Status: Equatable {
        let permission: String
        let registered: Bool
        let appVersion: String

        var json: [String: Any] {
            ["permission": permission, "registered": registered, "appVersion": appVersion]
        }
    }

    func status() async -> Status {
        let settings = await center.notificationSettings()
        return Status(permission: Self.permission(settings.authorizationStatus),
                      registered: registeredFor != nil,
                      appVersion: DriveController.appVersion)
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated static func permission(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .provisional: return "provisional"
        default: return "notDetermined"
        }
    }

    nonisolated static func allowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
