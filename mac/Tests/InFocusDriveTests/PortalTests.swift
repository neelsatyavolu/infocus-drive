import XCTest
@testable import InFocusDrive

final class AppConfigTests: XCTestCase {
    func testReadsOrigins() {
        let config = AppConfig(info: [
            "InFocusPortalURL": "https://portal.example.com/",
            "InFocusDriveURL": " https://drive.example.com ",
        ])
        XCTAssertEqual(config.portalURL?.absoluteString, "https://portal.example.com")
        XCTAssertEqual(config.driveURL?.absoluteString, "https://drive.example.com")
        XCTAssertEqual(config.portalHost, "portal.example.com")
    }

    func testEmptyPlaceholderAndUnsafeValuesAreNil() {
        for raw in ["", "  ", "__PORTAL_URL__", "http://portal.example.com", "ftp://portal.example.com", "portal"] {
            XCTAssertNil(AppConfig.origin(raw), raw)
        }
        XCTAssertNil(AppConfig(info: [:]).portalURL)
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

    func testEverythingElseOpensInTheBrowser() {
        XCTAssertEqual(decide("https://www.youtube.com/watch?v=1"), .external)
        XCTAssertEqual(decide("https://evilportal.example.com/"), .external) // not a subdomain
        XCTAssertEqual(decide("https://portal.example.com.evil.test/"), .external)
        XCTAssertEqual(decide("mailto:someone@example.org"), .external)
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
    /// RFC 7636 Appendix B.
    func testChallengeMatchesTheRFCVector() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIsURLSafeAndLongEnough() {
        let verifier = PKCE.random(bytes: 32)
        XCTAssertEqual(verifier.count, 43)
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(verifier, PKCE.random(bytes: 32))
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

    func testTokenResponseBecomesTheSessionCookie() throws {
        let body = #"{"data":{"token":"t.sig","maxAgeSeconds":2592000,"cookie":{"name":"infocus_session","domain":".portal.example.com","path":"/"}}}"#
        let token = try PortalAPI.decode(AppSessionToken.self, from: Data(body.utf8))
        let now = Date(timeIntervalSince1970: 1_000)
        let cookie = try XCTUnwrap(token.httpCookie(portal: URL(string: "https://portal.example.com")!, now: now))
        XCTAssertEqual(cookie.name, "infocus_session")
        XCTAssertEqual(cookie.value, "t.sig")
        XCTAssertEqual(cookie.domain, ".portal.example.com")
        XCTAssertEqual(cookie.path, "/")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.expiresDate, now.addingTimeInterval(2_592_000))
        XCTAssertTrue(PortalCookies.matches(cookie, host: "portal.example.com"))
        XCTAssertTrue(PortalCookies.matches(cookie, host: "grades.portal.example.com"))
    }

    func testHostOnlyCookieWhenNoDomain() throws {
        let body = #"{"data":{"token":"t","maxAgeSeconds":60,"cookie":{"name":"infocus_session","domain":null,"path":"/"}}}"#
        let token = try PortalAPI.decode(AppSessionToken.self, from: Data(body.utf8))
        let cookie = try XCTUnwrap(token.httpCookie(portal: URL(string: "https://portal.example.com")!))
        XCTAssertTrue(PortalCookies.matches(cookie, host: "portal.example.com"))
        XCTAssertFalse(PortalCookies.matches(cookie, host: "evil.test"))
    }

    func testErrorMessage() {
        XCTAssertEqual(PortalAPI.errorMessage(Data(#"{"error":{"message":"Code expired."}}"#.utf8)), "Code expired.")
        XCTAssertNil(PortalAPI.errorMessage(Data(#"{"error":"flat"}"#.utf8)))
        XCTAssertNil(PortalAPI.errorMessage(Data("not json".utf8)))
    }

    func testSignOutScope() {
        let host = "portal.example.com"
        XCTAssertTrue(PortalCookies.belongsToPortal("portal.example.com", portalHost: host))
        XCTAssertTrue(PortalCookies.belongsToPortal(".portal.example.com", portalHost: host))
        XCTAssertTrue(PortalCookies.belongsToPortal("grades.portal.example.com", portalHost: host))
        XCTAssertTrue(PortalCookies.belongsToPortal("example.com", portalHost: host)) // parent-domain cookies
        XCTAssertFalse(PortalCookies.belongsToPortal("youtube.com", portalHost: host))
        XCTAssertFalse(PortalCookies.belongsToPortal("", portalHost: host))
    }
}

final class PushRegistrarTests: XCTestCase {
    func testTokenIsLowercaseHex() {
        XCTAssertEqual(PushRegistrar.hex(Data([0x00, 0x0f, 0xab, 0xff])), "000fabff")
    }

    func testPermissionNames() {
        XCTAssertEqual(PushRegistrar.permission(.authorized), "authorized")
        XCTAssertEqual(PushRegistrar.permission(.denied), "denied")
        XCTAssertEqual(PushRegistrar.permission(.provisional), "provisional")
        XCTAssertEqual(PushRegistrar.permission(.notDetermined), "notDetermined")
        XCTAssertTrue(PushRegistrar.allowed(.provisional))
        XCTAssertFalse(PushRegistrar.allowed(.denied))
    }
}

final class AppRenameTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/student1")

    func testRenamesOnlyTheOldBundleInApplications() {
        XCTAssertEqual(AppRename.target(for: URL(fileURLWithPath: "/Applications/InFocus Drive.app"), home: home)?.path,
                       "/Applications/InFocus.app")
        XCTAssertEqual(AppRename.target(for: URL(fileURLWithPath: "/Users/student1/Applications/InFocus Drive.app"), home: home)?.path,
                       "/Users/student1/Applications/InFocus.app")
        XCTAssertNil(AppRename.target(for: URL(fileURLWithPath: "/Applications/InFocus.app"), home: home))
        XCTAssertNil(AppRename.target(for: URL(fileURLWithPath: "/Users/student1/Downloads/InFocus Drive.app"), home: home))
        XCTAssertNil(AppRename.target(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/InFocus Drive.app"), home: home))
    }
}

final class DownloadTests: XCTestCase {
    func testNeverOverwrites() {
        let folder = URL(fileURLWithPath: "/tmp/dl")
        var taken: Set<String> = ["/tmp/dl/clip.mov", "/tmp/dl/clip 2.mov"]
        let next = PortalDownloads.uniqueDestination(for: "clip.mov", in: folder) { taken.contains($0.path) }
        XCTAssertEqual(next.path, "/tmp/dl/clip 3.mov")
        taken = []
        XCTAssertEqual(PortalDownloads.uniqueDestination(for: "../../etc/passwd", in: folder) { taken.contains($0.path) }.path,
                       "/tmp/dl/passwd")
        XCTAssertEqual(PortalDownloads.uniqueDestination(for: "", in: folder) { _ in false }.path, "/tmp/dl/Download")
    }
}

final class MoveToApplicationsTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/student1")

    func testInstalledOnlyInsideAnApplicationsFolder() {
        XCTAssertTrue(MoveToApplications.isInstalled(URL(fileURLWithPath: "/Applications/InFocus.app"), home: home))
        XCTAssertTrue(MoveToApplications.isInstalled(URL(fileURLWithPath: "/Applications/Utilities/InFocus.app"), home: home))
        XCTAssertTrue(MoveToApplications.isInstalled(URL(fileURLWithPath: "/Users/student1/Applications/InFocus.app"), home: home))
        XCTAssertFalse(MoveToApplications.isInstalled(URL(fileURLWithPath: "/Users/student1/Downloads/InFocus Drive.app"), home: home))
        XCTAssertFalse(MoveToApplications.isInstalled(
            URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234/d/InFocus Drive.app"), home: home))
        XCTAssertFalse(MoveToApplications.isInstalled(URL(fileURLWithPath: "/ApplicationsBackup/InFocus.app"), home: home))
    }

    func testOffersOnlyForAForegroundAppBundleOutsideApplications() {
        let download = URL(fileURLWithPath: "/Users/student1/Downloads/InFocus Drive.app")
        XCTAssertTrue(MoveToApplications.shouldOffer(bundle: download, home: home, background: false, declined: false))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: download, home: home, background: true, declined: false))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: download, home: home, background: false, declined: true))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: URL(fileURLWithPath: "/Applications/InFocus.app"),
                                                      home: home, background: false, declined: false))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: URL(fileURLWithPath: "/tmp/.build/debug"),
                                                      home: home, background: false, declined: false))
    }

    func testNonAdminsGetTheirOwnApplicationsFolder() {
        XCTAssertEqual(MoveToApplications.destinationFolder(home: home, systemWritable: true).path, "/Applications")
        XCTAssertEqual(MoveToApplications.destinationFolder(home: home, systemWritable: false).path, "/Users/student1/Applications")
    }
}
