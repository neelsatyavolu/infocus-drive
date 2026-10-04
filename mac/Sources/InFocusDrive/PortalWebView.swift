import AppKit
import WebKit

/// Where a top-level navigation goes. Portal pages (the Portal host and its
/// subdomains: grades., equipment., …) stay in the app; Google sign-in is
/// replaced by the native hand-off (Google refuses embedded web views);
/// everything else opens in the default browser.
enum PortalNavigation: Equatable {
    case inApp, signIn, external

    static let googleStartPath = "/api/auth/google/start"

    static func isPortal(_ host: String?, portalHost: String) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty, !portalHost.isEmpty else { return false }
        return host == portalHost || host.hasSuffix("." + portalHost)
    }

    /// `externalHosts` always open in the browser even under the Portal's
    /// domain (the Drive website).
    static func decide(_ url: URL, portalHost: String, externalHosts: Set<String> = []) -> PortalNavigation {
        switch url.scheme?.lowercased() {
        case "about", "blob", "data":
            return .inApp
        case "http", "https":
            let host = url.host?.lowercased() ?? ""
            guard !externalHosts.contains(host), isPortal(host, portalHost: portalHost) else { return .external }
            return url.path == googleStartPath ? .signIn : .inApp
        default:
            return .external // mailto:, tel:, other apps
        }
    }

    /// Camera and microphone (Portal meetings) only for the configured Portal
    /// origin itself: same scheme and exact host, never another site or subdomain.
    static func allowsMediaCapture(scheme: String, host: String, portal: URL) -> Bool {
        guard let portalScheme = portal.scheme?.lowercased(), let portalHost = portal.host?.lowercased(),
              !portalHost.isEmpty else { return false }
        return scheme.lowercased() == portalScheme && host.lowercased() == portalHost
    }

    /// The Portal page a sign-in link asked to return to (`returnTo=/path`),
    /// only if it's a plain path on the Portal.
    static func returnTo(from url: URL, portal: URL) -> URL? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "returnTo" })?.value,
              raw.hasPrefix("/"), !raw.hasPrefix("//"), !raw.contains("\\"),
              let target = URL(string: raw, relativeTo: portal)?.absoluteURL,
              target.host == portal.host else { return nil }
        return target
    }
}

/// One Portal web view: navigation policy, downloads, file pickers and the
/// alert/confirm/prompt panels the Portal uses.
@MainActor
final class PortalWebController: NSObject {
    let webView: WKWebView
    let portal: URL
    private let drive: DriveController

    /// Ends like Safari's, plus the token the Portal looks for (`/InFocusMacApp/i`).
    static var userAgentSuffix: String {
        "Version/18.0 Safari/605.1.15 InFocusMacApp/\(DriveController.appVersion)"
    }

    init(portal: URL, drive: DriveController) {
        self.portal = portal
        self.drive = drive
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // cookies survive restarts
        config.applicationNameForUserAgent = Self.userAgentSuffix
        if #available(macOS 12.3, *) { config.preferences.isElementFullscreenEnabled = true }
        config.userContentController.addScriptMessageHandler(
            PortalBridge(portal: portal), contentWorld: .page, name: "infocus")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    private var externalHosts: Set<String> {
        let drives = [AppConfig.shared.driveURL?.host, URL(string: drive.serverURL)?.host]
        return Set(drives.compactMap { $0?.lowercased() })
    }

    private func route(_ request: URLRequest) -> PortalNavigation? {
        guard let url = request.url, let host = portal.host?.lowercased() else { return nil }
        return PortalNavigation.decide(url, portalHost: host, externalHosts: externalHosts)
    }

    private func signIn(from url: URL) {
        PortalSignIn.shared.signIn(drive: drive, returnTo: PortalNavigation.returnTo(from: url, portal: portal),
                                   webView: webView)
    }
}

extension PortalWebController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download) }
        // Frames (video players, embeds) load whatever they need.
        guard action.targetFrame?.isMainFrame ?? true, let url = action.request.url else {
            return decisionHandler(.allow)
        }
        switch route(action.request) {
        case .inApp?, nil:
            decisionHandler(.allow)
        case .external?:
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        case .signIn?:
            decisionHandler(.cancel)
            signIn(from: url)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        if disposition?.lowercased().hasPrefix("attachment") == true || !response.canShowMIMEType {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = PortalDownloads.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = PortalDownloads.shared
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Catches every way of signing in (Google hand-off, email code, account switch).
        PushRegistrar.shared.syncIfNeeded()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension PortalWebController: WKUIDelegate {
    /// target=_blank and window.open: Portal pages replace this one, others go to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        switch route(action.request) {
        case .inApp?: webView.load(action.request)
        case .signIn?: signIn(from: url)
        case .external?, nil: NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = Self.alert(message, buttons: ["OK"])
        present(alert, in: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = Self.alert(message, buttons: ["OK", "Cancel"])
        present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = Self.alert(prompt, buttons: ["OK", "Cancel"])
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// Meetings on the Portal: grant camera and microphone to the Portal origin
    /// only (macOS still asks the person once per app); deny everything else.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let allowed = PortalNavigation.allowsMediaCapture(scheme: origin.protocol, host: origin.host, portal: portal)
        decisionHandler(allowed ? .grant : .deny)
    }

    private static func alert(_ message: String, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }

    private func present(_ alert: NSAlert, in webView: WKWebView,
                         completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

/// `window.webkit.messageHandlers.infocus.postMessage({ action })` for Portal
/// Settings → Mac app notifications. Answers Portal pages only.
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

/// Saves Portal downloads to ~/Downloads without overwriting anything.
final class PortalDownloads: NSObject, WKDownloadDelegate {
    static let shared = PortalDownloads()

    /// "clip.mov" → "clip.mov", then "clip 2.mov", "clip 3.mov", …
    static func uniqueDestination(for suggested: String, in folder: URL,
                                  exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let clean = (suggested as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
        let name = clean.isEmpty || clean == "." || clean == ".." ? "Download" : clean
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        completionHandler(Self.uniqueDestination(for: suggestedFilename, in: folder))
    }

    func downloadDidFinish(_ download: WKDownload) {
        // Bounces the Downloads stack in the Dock, like Safari.
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"), object: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSLog("InFocus: download failed: %@", error.localizedDescription)
    }
}
