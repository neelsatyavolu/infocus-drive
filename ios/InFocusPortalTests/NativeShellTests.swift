import XCTest
@testable import InFocusPortal

final class RoleTests: XCTestCase {
    func testStudent() {
        let user = PortalUser.stub("student")
        XCTAssertFalse(user.isProducer)
        XCTAssertTrue(user.doesStudentWork)
        XCTAssertTrue(user.seesStudentGrades)
        XCTAssertEqual(AppTab.work.title(for: user), "Packages")
        XCTAssertEqual(user.displayName, "Abby")
    }

    func testAssociateOnAPackageDoesBoth() {
        var user = PortalUser.stub("associate")
        XCTAssertTrue(user.isProducer && user.isAssociate)
        XCTAssertTrue(user.doesStudentWork)
        user.onStudentPackage = false
        XCTAssertFalse(user.doesStudentWork)
        XCTAssertEqual(AppTab.work.title(for: user), "Groups")
    }

    func testAdviserIsSuperAdminButNotStage3() {
        let user = PortalUser(email: "adviser@example.edu", name: "Adviser Example", role: .adviser, onStudentPackage: false)
        XCTAssertTrue(user.isSuperAdmin)
        XCTAssertFalse(user.isExecutive)
        XCTAssertTrue(user.canManageGrades)
        XCTAssertFalse(user.seesStudentGrades)
        XCTAssertTrue(PortalUser.stub("admin").isExecutive)
    }
}

final class DeepLinkTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func resolve(_ string: String) -> DeepLinkMatch {
        DeepLink.resolve(URL(string: string)!, portal: portal)
    }

    func testNativeScreens() {
        XCTAssertEqual(resolve("https://portal.example.edu/dashboard"), DeepLinkMatch(tab: .home, route: nil))
        XCTAssertEqual(resolve("https://portal.example.edu/groups/row1/initial-cut"),
                       DeepLinkMatch(tab: .work, route: .work(.group(rowId: "row1", stage: "initial-cut"))))
        XCTAssertEqual(resolve("https://portal.example.edu/groups"), DeepLinkMatch(tab: .work, route: nil))
        XCTAssertEqual(resolve("https://portal.example.edu/a-roll"),
                       DeepLinkMatch(tab: .work, route: .work(.studentStage(.aRoll))))
        XCTAssertEqual(resolve("https://portal.example.edu/master-calendar?date=2026-10-07"),
                       DeepLinkMatch(tab: .calendar, route: .calendar(.day(date: "2026-10-07"))))
        XCTAssertEqual(resolve("https://portal.example.edu/announcements"),
                       DeepLinkMatch(tab: .calendar, route: .calendar(.announcements)))
        XCTAssertEqual(resolve("https://portal.example.edu/grades"), DeepLinkMatch(tab: .more, route: .grades(.grades)))
        XCTAssertEqual(resolve("https://portal.example.edu/extension-requests"),
                       DeepLinkMatch(tab: .more, route: .grades(.extensions)))
        XCTAssertEqual(resolve("https://equipment.portal.example.edu/"),
                       DeepLinkMatch(tab: .more, route: .messages(.equipment)))
        XCTAssertEqual(resolve("https://grades.portal.example.edu/"), DeepLinkMatch(tab: .more, route: .grades(.grades)))
    }

    func testEverythingElseOpensThePortalPage() {
        let url = URL(string: "https://portal.example.edu/publishing-queue")!
        XCTAssertEqual(DeepLink.resolve(url, portal: portal), DeepLinkMatch(tab: nil, route: .portal(PortalPage(url: url))))
        let submitted = URL(string: "https://portal.example.edu/announcements/submitted")!
        XCTAssertEqual(DeepLink.resolve(submitted, portal: portal).route, .portal(PortalPage(url: submitted)))
    }

    @MainActor
    func testRouterOpensDeepLinksOnTheirTab() {
        let router = Router()
        router.portal = portal
        router.push(.more(.settings))
        router.open(URL(string: "https://portal.example.edu/groups/row1")!)
        XCTAssertEqual(router.selectedTab, .work)
        XCTAssertEqual(router.path(.work).wrappedValue, [.work(.group(rowId: "row1", stage: nil))])
        router.select(.work) // tapping the selected tab pops to its root
        XCTAssertEqual(router.path(.work).wrappedValue, [])
        router.openPortal("announcements/pa", title: "PA")
        XCTAssertEqual(router.path(.work).wrappedValue.first,
                       .portal(PortalPage(url: URL(string: "https://portal.example.edu/announcements/pa")!, title: "PA")))
    }
}

final class PortalPagesCatalogTests: XCTestCase {
    private let config = AppConfig(info: ["InFocusPortalURL": "https://portal.example.edu",
                                          "InFocusDriveURL": "https://drive.portal.example.edu"])

    private func titles(_ user: PortalUser) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: PortalPagesCatalog.sections(for: user, config: config)
            .map { ($0.title, $0.links.map(\.title)) })
    }

    func testStudentSeesTheCycleAndNoProducerTools() {
        let sections = titles(.stub("student"))
        XCTAssertEqual(sections["The Cycle"], ["Information", "Brainstorming", "A-roll/B-roll", "Initial Cut", "Final Cut"])
        XCTAssertEqual(sections["Producers"], ["Extension Requests"])
        XCTAssertEqual(sections["Admin"], ["Portal settings"])
        XCTAssertTrue(sections["Portal"]?.contains("Grades") == true)
    }

    func testExecutiveSeesProducerAndAdminTools() {
        let sections = titles(.stub("producer"))
        XCTAssertNil(sections["The Cycle"])
        XCTAssertTrue(sections["Producers"]?.contains("Grade Editor") == true)
        XCTAssertEqual(sections["Admin"], ["Admin Dashboard", "Portal settings", "Passwords"])
        XCTAssertFalse(sections["Portal"]?.contains("Grades") == true)
    }

    func testDriveOpensOutsideAndTeleprompterIsAPortalSubdomain() {
        let production = PortalPagesCatalog.sections(for: .stub("student"), config: config)
            .first { $0.title == "Production" }!.links
        XCTAssertEqual(production.first { $0.title == "InFocus Drive" }?.external, true)
        XCTAssertEqual(production.first { $0.title == "Teleprompter" }?.url.host, "teleprompter.portal.example.edu")
    }

    func testPageTitles() {
        XCTAssertEqual(PortalWebController.pageTitle("Class Board · InFocus Portal"), "Class Board")
        XCTAssertEqual(PortalWebController.pageTitle("InFocus Portal"), nil)
        XCTAssertEqual(PortalWebController.pageTitle("Brainstorming & Proof of Contact"), "Brainstorming & Proof of Contact")
    }
}

final class SampleAccountTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    func testOnlyHomeAndMore() {
        XCTAssertEqual(AppTab.visible(for: .stub("sample")), [.home, .more])
        XCTAssertEqual(AppTab.visible(for: .stub("student")), AppTab.allCases)
        XCTAssertEqual(PortalUser.stub("sample").roleLabel, "Sample account")
    }

    @MainActor
    func testRouterKeepsTheSampleAccountOnHomeAndSettings() {
        let router = Router()
        router.portal = portal
        router.sampleOnly = true
        router.open(URL(string: "https://portal.example.edu/groups/row1")!)
        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertEqual(router.path(.work).wrappedValue, [])
        router.push(.grades(.grades))
        XCTAssertEqual(router.path(.home).wrappedValue, [])
        router.open(URL(string: "https://portal.example.edu/settings")!)
        XCTAssertEqual(router.selectedTab, .more)
        XCTAssertEqual(router.path(.more).wrappedValue, [.more(.settings)])
        router.reset()
        XCTAssertFalse(router.sampleOnly)
    }

    @MainActor
    func testSessionLoadsTheSampleAccountFromProfileAlone() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = PortalClient(portal: portal, session: URLSession(configuration: config), cookies: { [] })
        var paths: [String] = []
        StubProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            return (200, Data(#"{"data":{"email":"review@example.edu","name":"App Review","nickname":null,"sampleOnly":true}}"#.utf8))
        }
        defer { StubProtocol.handler = nil }
        let session = SessionStore()
        await session.load(using: client)
        XCTAssertEqual(session.user?.sampleOnly, true)
        XCTAssertEqual(paths, ["/api/profile"]) // never the 403 areas
    }
}

final class EmbeddedCookieTests: XCTestCase {
    func testPortalPagesKnowTheyAreInTheApp() throws {
        let cookie = try XCTUnwrap(PortalWebController.embeddedCookie(portal: URL(string: "https://portal.example.edu")!))
        XCTAssertEqual(cookie.name, "infocus_embedded")
        XCTAssertEqual(cookie.value, "1")
        XCTAssertEqual(cookie.domain, "portal.example.edu")
        XCTAssertTrue(cookie.isSecure)
    }
}
