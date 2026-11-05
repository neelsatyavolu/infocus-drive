import Foundation
import WebKit

/// The cycle a held student works on (the web sidebar's cycle switch, `components/shell/cycle-card.tsx`).
/// A student whose previous cycle's Final Cut isn't in stays on that cycle; when they're also on a
/// group in the active cycle, `GET api/package-cycle/stage` lists both as `cycleChoices`. The pick is
/// the `infocus_student_cycle` cookie (`STUDENT_CYCLE_COOKIE`), which the Portal honors only while
/// both cycles are valid. It goes in the web views' cookie store, which `PortalClient` sends from,
/// so native screens and Portal pages follow it alike.
enum StudentCycleChoice {
    static let cookieName = "infocus_student_cycle"
    /// 90 days, as the web sets it.
    static let maxAge = 60 * 60 * 24 * 90

    /// Posted after a switch so screens holding the old cycle (Home) load again.
    static let changed = Notification.Name("InFocusStudentCycleChanged")

    /// The same cookie the web writes: host-only, `path=/`, SameSite Lax, Secure on https.
    static func cookie(cycle: Int, portal: URL) -> HTTPCookie? {
        guard let host = portal.host else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookieName,
            .value: String(cycle),
            .domain: host,
            .path: "/",
            .maximumAge: String(maxAge),
            // Max-Age alone can leave a session cookie that a relaunch drops; the date keeps it 90 days.
            .expires: Date(timeIntervalSinceNow: TimeInterval(maxAge)),
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax,
        ]
        if portal.scheme == "https" { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    /// Saves the pick for every Portal call and web view.
    @MainActor
    static func choose(_ cycle: Int, portal: URL) async {
        guard let cookie = cookie(cycle: cycle, portal: portal) else { return }
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
