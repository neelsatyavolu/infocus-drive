import CryptoKit
import UIKit
import UserNotifications

/// iPhone notifications for Portal emails: asks iOS for permission, gets this
/// device's APNs token and registers it with the Portal under the signed-in
/// account (`POST /api/push/native-device`, platform "ios").
@MainActor
final class PushRegistrar: ObservableObject {
    static let shared = PushRegistrar()

    /// Lowercase hex APNs token, once iOS hands it over.
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

    /// At launch: Apple wants registration every launch. The token doesn't need
    /// alert permission (that only decides whether anything is shown).
    func start() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(_ token: Data) {
        deviceToken = Self.hex(token)
        Task { await sync(force: true) }
    }

    func didFail(_ error: Error) {
        NSLog("InFocus: iPhone notifications unavailable in this build: %@", error.localizedDescription)
    }

    /// Whether to show the "turn on notifications" pre-prompt (iOS only asks once).
    func shouldOfferPermission() async -> Bool {
        await center.notificationSettings().authorizationStatus == .notDetermined
    }

    /// The pre-prompt's Turn on, and the Portal's Settings bridge.
    func requestPermission() async -> Status {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            NSLog("InFocus: notification permission request failed: %@", error.localizedDescription)
        }
        UIApplication.shared.registerForRemoteNotifications()
        return await status()
    }

    /// After each Portal page load: registers when the session changed.
    func syncIfNeeded() {
        Task { await sync(force: false) }
    }

    func sync(force: Bool) async {
        guard let token = deviceToken, let portal = AppConfig.shared.portalURL, !syncing else { return }
        let cookies = await PortalCookies.forPortal(portal)
        guard let session = cookies.first(where: { $0.name == PortalCookies.sessionCookieName })?.value,
              !session.isEmpty else {
            registeredFor = nil
            return
        }
        let key = Self.fingerprint(token + "\n" + session)
        if !force, registeredFor == key { return }
        syncing = true
        defer { syncing = false }
        let ok = await send("POST", body: [
            "token": token, "environment": Self.environment, "appVersion": AppConfig.appVersion, "platform": "ios",
        ], cookies: cookies, portal: portal)
        registeredFor = ok ? key : nil
    }

    /// Sign out: this device stops getting the account's notifications.
    /// Runs while the session cookie still exists (the route needs it).
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
        // Settings asks often: retry anything unfinished (no token yet, or never sent).
        if deviceToken == nil {
            UIApplication.shared.registerForRemoteNotifications()
        } else if registeredFor == nil {
            await sync(force: true)
        }
        return Status(permission: Self.permission(settings.authorizationStatus),
                      registered: registeredFor != nil,
                      appVersion: AppConfig.appVersion)
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    nonisolated static func permission(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .ephemeral: return "authorized"
        case .denied: return "denied"
        case .provisional: return "provisional"
        default: return "notDetermined"
        }
    }

    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
