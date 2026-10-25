import AppKit
import UserNotifications

/// Shows Portal notifications even while the app is in front, and opens the
/// notification's Portal page when it's clicked. The APNs payload carries the
/// page as `url`; anything that isn't a Portal page opens the Portal home.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Set at launch; needed to open Portal windows.
    weak var drive: DriveController?

    static func destination(for userInfo: [AnyHashable: Any], portal: URL) -> URL {
        // Pushes may still name the Portal's old domain.
        guard let raw = userInfo["url"] as? String, let parsed = URL(string: raw),
              case let url = AppConfig.moved(parsed, to: portal.host?.lowercased() ?? "", from: AppConfig.shared.legacyHosts),
              url.scheme?.lowercased() == portal.scheme?.lowercased(),
              PortalNavigation.isPortal(url.host, portalHost: portal.host?.lowercased() ?? "") else {
            return portal
        }
        return url
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            if let portal = AppConfig.shared.portalURL, let drive = self.drive {
                Windows.shared.showPortal(drive, url: Self.destination(for: info, portal: portal))
            }
            completionHandler()
        }
    }
}
