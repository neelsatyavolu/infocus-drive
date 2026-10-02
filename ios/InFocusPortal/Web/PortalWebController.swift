import UIKit
import WebKit

/// What the web view hands back to the app: sign-in/out it can't do itself,
/// and every finished page (to notice a session that started or ended).
@MainActor
protocol PortalWebDelegate: AnyObject {
    func portalWebNeedsSignIn(returnTo: URL?)
    func portalWebRequestedSignOut()
    func portalWebDidFinish(_ url: URL?)
}

/// Why the Portal couldn't be shown.
enum PortalLoadFailure: Equatable {
    case offline, unavailable

    static func from(_ error: Error) -> PortalLoadFailure? {
        let error = error as NSError
        // Cancelled loads (a new navigation replaced this one) aren't failures;
        // 102 is WebKit's "frame load interrupted" (a download took over).
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102) { return nil }
        let offline: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                                 NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                                 NSURLErrorDNSLookupFailed, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]
        return error.domain == NSURLErrorDomain && offline.contains(error.code) ? .offline : .unavailable
    }

    /// Gateway and maintenance errors get the native screen; other statuses
    /// show the Portal's own page.
    static func from(status: Int) -> PortalLoadFailure? {
        [502, 503, 504].contains(status) ? .unavailable : nil
    }
}

/// The Portal's web view: navigation policy, downloads, new windows and the
/// alert/confirm/prompt panels the Portal uses.
@MainActor
final class PortalWebController: NSObject, ObservableObject {
    let webView: WKWebView
    let portal: URL
    weak var delegate: PortalWebDelegate?

    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var failure: PortalLoadFailure?
    /// The page's `<title>`, for a native navigation title.
    @Published private(set) var title: String?
    @Published private(set) var canGoBack = false

    private var observations: [NSKeyValueObservation] = []
    private let downloads = PortalDownloads()

    /// Mobile Safari's, plus the token the Portal looks for (`/InFocusiOSApp/i`).
    nonisolated static var userAgentSuffix: String {
        "Version/18.0 Mobile/15E148 Safari/604.1 InFocusiOSApp/\(AppConfig.appVersion)"
    }

    /// A page pushed inside a NavigationStack (`embedded`) leaves the edge
    /// swipe to the native back gesture instead of the web history.
    init(portal: URL, embedded: Bool = false) {
        self.portal = portal
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // cookies survive restarts
        config.applicationNameForUserAgent = Self.userAgentSuffix
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.addScriptMessageHandler(PortalBridge(portal: portal), contentWorld: .page, name: "infocus")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = !embedded
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = Brand.uiBackground
        webView.scrollView.backgroundColor = Brand.uiBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never // the Portal pads for the safe area itself
        #if DEBUG
        webView.isInspectable = true
        #endif
        addPullToRefresh()
        observations = [
            webView.observe(\.estimatedProgress, options: .new) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.progress = web.estimatedProgress }
            },
            webView.observe(\.isLoading, options: .new) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.isLoading = web.isLoading }
            },
            webView.observe(\.title, options: .new) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.title = Self.pageTitle(web.title) }
            },
            webView.observe(\.canGoBack, options: .new) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoBack = web.canGoBack }
            },
        ]
    }

    /// "Class Board · InFocus Portal" → "Class Board"; the bare site name → nil.
    nonisolated static func pageTitle(_ raw: String?) -> String? {
        let title = raw?.components(separatedBy: " · ").first?
            .components(separatedBy: " | ").first?.trimmingCharacters(in: .whitespaces)
        return title?.isEmpty == false && title != "InFocus Portal" ? title : nil
    }

    func load(_ url: URL) {
        failure = nil
        webView.load(URLRequest(url: url))
    }

    /// Retry from the offline screen: the page that failed, or the dashboard.
    func retry(fallback: URL) {
        failure = nil
        if let url = webView.url, url.scheme?.hasPrefix("http") == true {
            webView.load(URLRequest(url: url))
        } else {
            load(fallback)
        }
    }

    private func addPullToRefresh() {
        let refresh = UIRefreshControl()
        refresh.tintColor = Brand.uiGreen
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            self?.webView.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refresh?.endRefreshing() }
        }, for: .valueChanged)
        webView.scrollView.refreshControl = refresh
    }

    private func route(_ url: URL) -> PortalNavigation? {
        guard let host = portal.host?.lowercased() else { return nil }
        return PortalNavigation.decide(url, portalHost: host, externalHosts: AppConfig.shared.externalHosts)
    }

    /// Other sites open in Safari's in-app sheet (or their app, for universal
    /// links like YouTube); other schemes (mailto:, tel:) go to the system.
    private func openOutside(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
            if !opened { Presenter.showSafari(url) }
        }
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
        switch route(url) {
        case .inApp?, nil:
            decisionHandler(.allow)
        case .external?:
            decisionHandler(.cancel)
            openOutside(url)
        case .signIn?:
            decisionHandler(.cancel)
            delegate?.portalWebNeedsSignIn(returnTo: PortalNavigation.returnTo(from: url, portal: portal))
        case .signOut?:
            decisionHandler(.cancel)
            delegate?.portalWebRequestedSignOut()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = response.response as? HTTPURLResponse
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")
        if disposition?.lowercased().hasPrefix("attachment") == true || !response.canShowMIMEType {
            return decisionHandler(.download)
        }
        if response.isForMainFrame, let status = http?.statusCode, let failure = PortalLoadFailure.from(status: status) {
            self.failure = failure
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failure = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Catches every way of signing in or out (Google hand-off, email code, expiry).
        delegate?.portalWebDidFinish(webView.url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = PortalLoadFailure.from(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension PortalWebController: WKUIDelegate {
    /// target=_blank and window.open: Portal pages replace this one, others leave the app.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        switch route(url) {
        case .inApp?: webView.load(action.request)
        case .signIn?: delegate?.portalWebNeedsSignIn(returnTo: PortalNavigation.returnTo(from: url, portal: portal))
        case .signOut?: delegate?.portalWebRequestedSignOut()
        case .external?, nil: openOutside(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        Presenter.present(alert, orElse: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        Presenter.present(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        Presenter.present(alert) { completionHandler(nil) }
    }

    /// Camera and microphone for Portal pages only (video notes, uploads); iOS still asks the person.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let portalHost = portal.host?.lowercased() ?? ""
        decisionHandler(origin.protocol == portal.scheme && PortalNavigation.isPortal(origin.host, portalHost: portalHost)
                        ? .prompt : .deny)
    }
}
