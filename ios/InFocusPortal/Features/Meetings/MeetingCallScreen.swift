import AVFoundation
import SwiftUI
import UIKit

/// A meeting the app is showing full screen (`Router.activeCall`).
struct MeetingCall: Identifiable, Hashable {
    let id: String
}

/// The call: the Portal's `/meet/<id>?app=1` page full screen (no tab bar, dark),
/// in the same signed-in web view setup as every Portal page. The page renders its
/// own Leave flow and then navigates to `/meetings?left=1`, which closes this screen.
struct MeetingCallScreen: View {
    let meetingId: String
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var call: MeetingCallController

    init(meetingId: String, onClose: (() -> Void)? = nil) {
        self.meetingId = meetingId
        self.onClose = onClose
        _call = StateObject(wrappedValue: MeetingCallController(meetingId: meetingId))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            PortalWebView(controller: call.web) // inside the safe area: notch and home indicator stay clear
            if call.web.isLoading && !call.hasLoaded {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let failure = call.web.failure {
                OfflineView(failure: failure) { call.web.retry(fallback: call.url) }
                    .background(Brand.background)
                // The page's own Leave isn't there when it failed to load.
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.lexend(17, .semibold))
                        .foregroundStyle(Brand.foreground)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close meeting")
                .padding(.leading, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: call.left) { _, left in if left { close() } }
        .onAppear { call.begin() }
        .onDisappear { call.end() }
    }

    private func close() {
        call.end()
        if let onClose { onClose() } else { dismiss() }
    }
}

/// Owns the call's web view, audio session and idle timer.
@MainActor
final class MeetingCallController: ObservableObject {
    let web: PortalWebController
    let url: URL
    @Published private(set) var left = false
    @Published private(set) var hasLoaded = false

    private var observation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var savedAudio: (category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                             options: AVAudioSession.CategoryOptions)?
    private var savedIdleTimer = false
    private var active = false

    init(meetingId: String) {
        let portal = AppConfig.shared.portalURL ?? URL(string: "https://portal.invalid")!
        url = Self.callURL(portal: portal, meetingId: meetingId)
        web = PortalWebController(portal: portal, embedded: true)
        web.delegate = AppModel.shared
        web.webView.scrollView.refreshControl = nil // a pull must never reload the call
        web.webView.scrollView.bounces = false
        web.webView.backgroundColor = .black
        web.webView.scrollView.backgroundColor = .black
        // The Portal leaves with a client-side navigation, so watch the URL, not navigation actions.
        observation = web.webView.observe(\.url, options: .new) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self, let current = webView.url else { return }
                if Self.isLeaveURL(current, portal: portal) { self.left = true }
            }
        }
        loadingObservation = web.webView.observe(\.isLoading, options: .new) { [weak self] webView, _ in
            MainActor.assumeIsolated { if !webView.isLoading { self?.hasLoaded = true } }
        }
        web.load(url)
    }

    nonisolated static func callURL(portal: URL, meetingId: String) -> URL {
        var parts = URLComponents(url: portal.appendingPathComponent("meet").appendingPathComponent(meetingId),
                                  resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "app", value: "1")]
        return parts.url!
    }

    /// The Portal page left the call: `/meetings?left=1` (or any Meetings page) on the Portal host.
    nonisolated static func isLeaveURL(_ url: URL, portal: URL) -> Bool {
        guard url.host?.lowercased() == portal.host?.lowercased() else { return false }
        return url.path == "/meetings" || url.path.hasPrefix("/meetings/")
    }

    /// Call audio (speaker by default, Bluetooth headsets allowed) and no auto-lock.
    func begin() {
        guard !active else { return }
        active = true
        let session = AVAudioSession.sharedInstance()
        savedAudio = (session.category, session.mode, session.categoryOptions)
        do {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            // WebKit still gets audio with its own defaults.
        }
        savedIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Stops the page (camera and mic off) and restores audio and auto-lock.
    func end() {
        guard active else { return }
        active = false
        web.webView.stopLoading()
        web.webView.loadHTMLString("", baseURL: nil) // tears down the call's media in the page
        UIApplication.shared.isIdleTimerDisabled = savedIdleTimer
        let session = AVAudioSession.sharedInstance()
        if let saved = savedAudio {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(saved.category, mode: saved.mode, options: saved.options)
        }
        savedAudio = nil
    }
}
