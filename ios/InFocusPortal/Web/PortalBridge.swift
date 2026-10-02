import WebKit

/// `window.webkit.messageHandlers.infocus.postMessage({ action })` for Portal
/// Settings → app notifications (same replies as the Mac app). Answers Portal
/// pages only.
final class PortalBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let portal: URL

    init(portal: URL) {
        self.portal = portal
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == portal.scheme,
              PortalNavigation.isPortal(origin.host, portalHost: portal.host?.lowercased() ?? "") else {
            return replyHandler(nil, "Not allowed")
        }
        let action = (message.body as? [String: Any])?["action"] as? String
        Task { @MainActor in
            let push = PushRegistrar.shared
            switch action {
            case "notificationStatus":
                replyHandler(await push.status().json, nil)
            case "requestNotifications":
                replyHandler(await push.requestPermission().json, nil)
            case "openNotificationSettings":
                push.openSystemSettings()
                replyHandler(["ok": true], nil)
            default:
                replyHandler(nil, "Unknown action")
            }
        }
    }
}
