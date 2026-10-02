import XCTest
@testable import InFocusPortal

final class AppConfigTests: XCTestCase {
    func testReadsOriginsAndHome() {
        let config = AppConfig(info: [
            "InFocusPortalURL": "https://portal.example.com/",
            "InFocusDriveURL": " https://drive.portal.example.com ",
        ])
        XCTAssertEqual(config.portalURL?.absoluteString, "https://portal.example.com")
        XCTAssertEqual(config.homeURL?.absoluteString, "https://portal.example.com/dashboard")
        XCTAssertEqual(config.portalHost, "portal.example.com")
        XCTAssertEqual(config.externalHosts, ["drive.portal.example.com"])
    }

    func testEmptyHostsAndUnsafeValuesAreNil() {
        // An empty INFOCUS_DRIVE_HOST builds as "https://".
        for raw in ["", "  ", "https://", "http://portal.example.com", "ftp://portal.example.com", "portal"] {
            XCTAssertNil(AppConfig.origin(raw), raw)
        }
        XCTAssertNil(AppConfig(info: [:]).portalURL)
        XCTAssertEqual(AppConfig(info: ["InFocusDriveURL": "https://"]).externalHosts, [])
    }

    func testStripsPathAndAllowsLocalhost() {
        XCTAssertEqual(AppConfig.origin("https://portal.example.com/dashboard?x=1#y")?.absoluteString,
                       "https://portal.example.com")
        XCTAssertEqual(AppConfig.origin("http://localhost:3000")?.absoluteString, "http://localhost:3000")
    }
}

final class PortalNavigationTests: XCTestCase {
    private let host = "portal.example.com"
    private let portal = URL(string: "https://portal.example.com")!

    private func decide(_ raw: String, external: Set<String> = []) -> PortalNavigation {
        PortalNavigation.decide(URL(string: raw)!, portalHost: host, externalHosts: external)
    }

    func testPortalAndSubdomainsStayInApp() {
        XCTAssertEqual(decide("https://portal.example.com/groups"), .inApp)
        XCTAssertEqual(decide("https://grades.portal.example.com/"), .inApp)
        XCTAssertEqual(decide("https://portal.example.com/sign-in?returnTo=%2Fgroups"), .inApp)
        XCTAssertEqual(decide("about:blank"), .inApp)
        XCTAssertEqual(decide("blob:https://portal.example.com/1234"), .inApp)
    }

    func testGoogleStartIsInterceptedOnlyOnThePortal() {
        XCTAssertEqual(decide("https://portal.example.com/api/auth/google/start?returnTo=%2Fgroups"), .signIn)
        XCTAssertEqual(decide("https://equipment.portal.example.com/api/auth/google/start?equipment=1"), .signIn)
        XCTAssertEqual(decide("https://other.example.com/api/auth/google/start"), .external)
    }

    func testSignOutRunsNatively() {
        XCTAssertEqual(decide("https://portal.example.com/api/auth/sign-out?returnTo=/"), .signOut)
        XCTAssertEqual(decide("https://other.example.com/api/auth/sign-out"), .external)
    }

    func testEverythingElseLeavesTheApp() {
        XCTAssertEqual(decide("https://www.youtube.com/watch?v=1"), .external)
        XCTAssertEqual(decide("https://evilportal.example.com/"), .external) // not a subdomain
        XCTAssertEqual(decide("https://portal.example.com.evil.test/"), .external)
        XCTAssertEqual(decide("mailto:someone@example.org"), .external)
        XCTAssertEqual(decide("tel:5555550100"), .external)
        XCTAssertEqual(decide("https://drive.portal.example.com/", external: ["drive.portal.example.com"]), .external)
    }

    func testReturnToMustBeAPortalPath() {
        func returnTo(_ query: String) -> String? {
            PortalNavigation.returnTo(from: URL(string: "https://portal.example.com/api/auth/google/start?\(query)")!,
                                      portal: portal)?.absoluteString
        }
        XCTAssertEqual(returnTo("returnTo=%2Fgroups%3Ftab%3D1"), "https://portal.example.com/groups?tab=1")
        XCTAssertNil(returnTo("returnTo=%2F%2Fevil.test%2F"))
        XCTAssertNil(returnTo("returnTo=https%3A%2F%2Fevil.test%2F"))
        XCTAssertNil(returnTo("returnTo=%2F%5Cevil.test"))
        XCTAssertNil(returnTo("equipment=1"))
    }

    func testSignInPage() {
        XCTAssertTrue(PortalNavigation.isSignInPage(URL(string: "https://portal.example.com/sign-in?returnTo=%2Fgroups"),
                                                    portalHost: host))
        XCTAssertTrue(PortalNavigation.isSignInPage(URL(string: "https://grades.portal.example.com/sign-in"), portalHost: host))
        XCTAssertFalse(PortalNavigation.isSignInPage(URL(string: "https://portal.example.com/dashboard"), portalHost: host))
        XCTAssertFalse(PortalNavigation.isSignInPage(URL(string: "https://evil.test/sign-in"), portalHost: host))
        XCTAssertFalse(PortalNavigation.isSignInPage(nil, portalHost: host))
    }
}

final class NotificationRouterTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.com")!

    func testOpensPortalPages() {
        let url = NotificationRouter.destination(for: ["url": "https://portal.example.com/groups/abc"], portal: portal)
        XCTAssertEqual(url.absoluteString, "https://portal.example.com/groups/abc")
        let sub = NotificationRouter.destination(for: ["url": "https://grades.portal.example.com/"], portal: portal)
        XCTAssertEqual(sub.host, "grades.portal.example.com")
    }

    func testFallsBackToPortalHome() {
        for info: [AnyHashable: Any] in [
            [:], ["url": 42], ["url": "https://evil.test/"], ["url": "http://portal.example.com/groups"],
            ["url": "javascript:alert(1)"], ["url": "not a url"],
        ] {
            XCTAssertEqual(NotificationRouter.destination(for: info, portal: portal), portal)
        }
    }
}

final class SignInTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636Example() {
        // RFC 7636 appendix B.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomIsURLSafeAndUnpadded() {
        let value = PKCE.random(bytes: 32)
        XCTAssertEqual(value.count, 43)
        XCTAssertNil(value.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(value, PKCE.random(bytes: 32))
    }

    func testCallbackParsing() {
        func parse(_ raw: String) -> SignInCallback { SignInCallback.parse(URL(string: raw)!, state: "s1") }
        XCTAssertEqual(parse("infocus://signed-in?code=abc&state=s1"), .code("abc"))
        XCTAssertEqual(parse("infocus://signed-in?error=cancelled&state=s1"), .cancelled)
        XCTAssertEqual(parse("infocus://signed-in?code=abc&state=other"), .invalid)
        XCTAssertEqual(parse("infocus://signed-in?code=&state=s1"), .invalid)
        XCTAssertEqual(parse("infocus://elsewhere?code=abc&state=s1"), .invalid)
        XCTAssertEqual(parse("https://signed-in?code=abc&state=s1"), .invalid)
    }

    func testSessionCookie() throws {
        let json = #"{"data":{"token":"t0k","maxAgeSeconds":3600,"cookie":{"name":"infocus_session","path":"/"}}}"#
        let token = try PortalAPI.decode(AppSessionToken.self, from: Data(json.utf8))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cookie = try XCTUnwrap(token.httpCookie(portal: URL(string: "https://portal.example.com")!, now: now))
        XCTAssertEqual(cookie.name, "infocus_session")
        XCTAssertEqual(cookie.value, "t0k")
        XCTAssertEqual(cookie.domain, "portal.example.com")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.expiresDate, now.addingTimeInterval(3600))
    }

    func testErrorEnvelope() {
        XCTAssertEqual(PortalAPI.errorMessage(Data(#"{"error":{"message":"Code expired."}}"#.utf8)), "Code expired.")
        XCTAssertNil(PortalAPI.errorMessage(Data("nope".utf8)))
    }

    func testCookieMatching() {
        func cookie(_ domain: String) -> HTTPCookie {
            HTTPCookie(properties: [.name: "a", .value: "b", .domain: domain, .path: "/"])!
        }
        XCTAssertTrue(PortalCookies.matches(cookie("portal.example.com"), host: "portal.example.com"))
        XCTAssertTrue(PortalCookies.matches(cookie(".example.com"), host: "portal.example.com"))
        XCTAssertFalse(PortalCookies.matches(cookie("other.example.com"), host: "portal.example.com"))
        XCTAssertTrue(PortalCookies.belongsToPortal(".grades.portal.example.com", portalHost: "portal.example.com"))
        XCTAssertTrue(PortalCookies.belongsToPortal("example.com", portalHost: "portal.example.com"))
        XCTAssertFalse(PortalCookies.belongsToPortal("evil.test", portalHost: "portal.example.com"))
    }
}

final class PushAndWebTests: XCTestCase {
    func testTokenHex() {
        XCTAssertEqual(PushRegistrar.hex(Data([0x00, 0x0f, 0xab, 0xff])), "000fabff")
    }

    func testPermissionNames() {
        XCTAssertEqual(PushRegistrar.permission(.authorized), "authorized")
        XCTAssertEqual(PushRegistrar.permission(.denied), "denied")
        XCTAssertEqual(PushRegistrar.permission(.provisional), "provisional")
        XCTAssertEqual(PushRegistrar.permission(.notDetermined), "notDetermined")
    }

    func testLoadFailures() {
        XCTAssertEqual(PortalLoadFailure.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(PortalLoadFailure.from(URLError(.timedOut)), .offline)
        XCTAssertEqual(PortalLoadFailure.from(URLError(.badServerResponse)), .unavailable)
        XCTAssertNil(PortalLoadFailure.from(URLError(.cancelled)))
        XCTAssertNil(PortalLoadFailure.from(NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertEqual(PortalLoadFailure.from(status: 503), .unavailable)
        XCTAssertNil(PortalLoadFailure.from(status: 500)) // the Portal's own error page
        XCTAssertNil(PortalLoadFailure.from(status: 404))
    }

    func testDownloadDestinationKeepsSafeName() {
        let root = URL(fileURLWithPath: "/tmp/Downloads")
        XCTAssertEqual(PortalDownloads.destination(for: "clip.mov", in: root).lastPathComponent, "clip.mov")
        XCTAssertEqual(PortalDownloads.destination(for: "../../etc/passwd", in: root).lastPathComponent, "passwd")
        XCTAssertEqual(PortalDownloads.destination(for: "..", in: root).lastPathComponent, "Download")
        XCTAssertEqual(PortalDownloads.destination(for: "a.pdf", in: root).deletingLastPathComponent()
            .deletingLastPathComponent().path, root.path)
    }

    @MainActor
    func testUserAgentCarriesTheAppToken() {
        XCTAssertTrue(PortalWebController.userAgentSuffix.contains("Mobile/15E148 Safari/604.1"))
        XCTAssertNotNil(PortalWebController.userAgentSuffix.range(of: "InFocusiOSApp/", options: .caseInsensitive))
    }
}
