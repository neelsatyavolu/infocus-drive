import UIKit
import UserNotifications

/// Shows Portal notifications even while the app is in front, and opens the
/// notification's Portal page when it's tapped (also from a cold launch). The
/// APNs payload carries the page as `url`; anything that isn't a Portal page
/// opens the Portal home.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    static func destination(for userInfo: [AnyHashable: Any], portal: URL) -> URL {
        guard let raw = userInfo["url"] as? String, let url = URL(string: raw),
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
            if let portal = AppConfig.shared.portalURL {
                AppModel.shared.open(Self.destination(for: info, portal: portal))
            }
            completionHandler()
        }
    }
}
