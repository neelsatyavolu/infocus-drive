import XCTest
@testable import InFocusPortal

/// Every signed-in Portal page (app/(app) in the Portal repo, plus the
/// equipment and submit-announcement pages) opens a native screen. A page
/// that should stay on the web belongs in `webPages`, with the reason.
final class PortalParityTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private let nativePages = [
        "", "dashboard", "information", "brainstorming", "a-roll", "initial-cut", "final-cut",
        "groups", "groups/row1", "groups/row1/final-cut",
        "package-progress", "package-cycles", "members", "participation",
        "grades", "grade-editor", "extensions", "extension-requests",
        "master-calendar", "show-roles", "teleprompter",
        "announcements", "announcements/pa", "announcements/submitted", "submit-announcement",
        "equipment", "equipment/request", "equipment/manage", "livestreams",
        "publishing-queue", "publishing-queue/row1",
        "meetings", "meetings/m1",
        "workspaces", "projects/p1", "projects/p1/review/m1",
        "admin", "managers", "managers/social-media", "passwords", "settings", "activity",
        "ideas", "class-board",
    ]

    private func route(_ path: String) -> Route? {
        DeepLink.resolve(URL(string: "https://portal.example.edu/\(path)")!, portal: portal).route
    }

    func testEverySignedInPageOpensNatively() {
        for path in nativePages {
            if case .portal? = route(path) {
                XCTFail("/\(path) opens the web view")
            }
        }
    }

    func testGuestReviewPagesStayOnTheWeb() {
        // /g/<token> is for people without a Portal account.
        guard case .portal? = route("g/token1") else { return XCTFail("/g/<token> should stay a web page") }
    }
}
