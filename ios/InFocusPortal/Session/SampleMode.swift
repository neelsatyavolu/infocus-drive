import Foundation
import os

/// The sample app for Apple App Review. When the App Review account signs in
/// (`PortalUser.sampleOnly`, set by the Portal from `APP_REVIEW_EMAIL`), every
/// feature answers from its built-in fictional fixtures so reviewers can see the
/// whole app without any real student's records (FERPA). Nothing is written to
/// the Portal: `PortalClient` refuses every call except the few the account is
/// allowed (`allowedPaths`). Real accounts never turn this on.
///
/// DEBUG builds also turn it on with `-InFocusStubSession <kind>` (screenshots, previews).
enum SampleMode {
    private static let state = OSAllocatedUnfairLock(initialState: false)
    private static let blockedPaths = OSAllocatedUnfairLock(initialState: [String]())

    /// The only Portal calls the sample session makes: its profile, this iPhone's
    /// push registration and test notification, and notification preferences.
    static let allowedPaths = ["api/profile", "api/push/", "api/notification-preferences"]

    static let notice = "Sample app: changes aren't saved."

    static var isOn: Bool {
        if state.withLock({ $0 }) { return true }
        #if DEBUG
        return UserDefaults.standard.string(forKey: "InFocusStubSession") != nil
        #else
        return false
        #endif
    }

    static func set(_ on: Bool) {
        state.withLock { $0 = on }
    }

    static func allows(_ path: String) -> Bool {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return allowedPaths.contains { trimmed == $0 || trimmed.hasPrefix($0) }
    }

    /// A Portal call the sample session refused (tests read it; the app shows a notice).
    static func recordBlocked(_ path: String) {
        blockedPaths.withLock { $0.append(path) }
        notSaved()
    }

    /// A change the sample app took without saving it: tell the reviewer.
    static func notSaved() {
        Task { @MainActor in AppModel.shared.showSampleNotice() }
    }

    static var blocked: [String] { blockedPaths.withLock { $0 } }

    static func resetBlocked() {
        blockedPaths.withLock { $0 = [] }
    }
}
