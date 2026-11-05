import XCTest
@testable import InFocusPortal

/// Birthdays from Settings on the Master Calendar (Portal 2f19e65e). Fictional data only.
final class CalendarBirthdayTests: XCTestCase {
    private let json = """
    {"month":"2026-10","canEdit":false,"entries":[],"queuedPackages":[],"showManagers":{},
     "schedule":[{"date":"2026-10-29","kind":"NONE","label":""},{"date":"2026-10-30","kind":"SHOW","label":""}],
     "birthdays":{"2026-10-29":[{"name":"Abby","actualDate":null}],
                  "2026-10-30":[{"name":"Otto","actualDate":"2026-11-01"},{"name":"Sage","actualDate":null}]}}
    """

    func testBirthdaysDecodeAndLandOnTheirDays() throws {
        let month = try PortalJSON.decoder().decode(CalendarMonth.self, from: Data(json.utf8))
        let days = CalendarStore.days(from: month)
        XCTAssertEqual(days[0].birthdays.map(\.label), ["Abby"])
        XCTAssertEqual(days[1].birthdays.map(\.label), ["Otto (Sun, Nov 1)", "Sage"],
                       "a birthday moved back from a day off shows the real date, like the Portal's birthdayLabel")
    }

    func testOlderPortalHasNoBirthdays() throws {
        let older = #"{"month":"2026-10","canEdit":false,"entries":[],"schedule":[{"date":"2026-10-29","kind":"NONE","label":""}],"queuedPackages":[],"showManagers":{}}"#
        let month = try PortalJSON.decoder().decode(CalendarMonth.self, from: Data(older.utf8))
        XCTAssertNil(month.birthdays)
        XCTAssertEqual(CalendarStore.days(from: month).first?.birthdays, [])
    }

    func testStubMonthHasAFictionalBirthday() {
        let month = CalendarStubData.month("2026-10")
        XCTAssertEqual(month.birthdays?.values.flatMap { $0 }.map(\.name), ["Abby"])
    }
}
