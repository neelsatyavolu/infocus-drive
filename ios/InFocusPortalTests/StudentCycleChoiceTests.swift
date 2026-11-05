import XCTest
@testable import InFocusPortal

/// A held student's cycle switch: the Portal's choices and the web's cycle cookie.
final class StudentCycleChoiceTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    func testDecodesCycleChoicesOnlyForHeldStudents() throws {
        func gates(_ extra: String) throws -> StudentGates {
            try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<StudentGates>.self, from: Data("""
            {"data":{"cycleNumber":2,"hasRow":true\(extra),"unlocked":{"a-roll":true,"initial-cut":true,"final-cut":true},
              "statuses":{"final-cut":"pending"},"unread":{}}}
            """.utf8)).data
        }
        XCTAssertEqual(try gates(#","cycleChoices":[2,3]"#).cycleChoices, [2, 3])
        XCTAssertNil(try gates(#","cycleChoices":null"#).cycleChoices)
        XCTAssertNil(try gates("").cycleChoices, "an older Portal sends no choices")
    }

    func testCyclePickIsTheWebsCookieForThePortal() throws {
        let cookie = try XCTUnwrap(StudentCycleChoice.cookie(cycle: 3, portal: portal))
        XCTAssertEqual(cookie.name, "infocus_student_cycle")
        XCTAssertEqual(cookie.value, "3")
        XCTAssertEqual(cookie.path, "/")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertFalse(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.sameSitePolicy, .sameSiteLax)
        XCTAssertTrue(PortalCookies.matches(cookie, host: "portal.example.edu"), "PortalClient sends it with every call")
        XCTAssertFalse(PortalCookies.matches(cookie, host: "drive.example.edu"))
        let expires = try XCTUnwrap(cookie.expiresDate)
        XCTAssertEqual(expires.timeIntervalSinceNow, 90 * 86_400, accuracy: 60)
        let local = try XCTUnwrap(StudentCycleChoice.cookie(cycle: 2, portal: URL(string: "http://localhost:3000")!))
        XCTAssertFalse(local.isSecure)
    }
}
