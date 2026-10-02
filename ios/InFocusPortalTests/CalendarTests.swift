import XCTest
@testable import InFocusPortal

final class DayContentTests: XCTestCase {
    func testReadsHeadingsNamesAndLines() {
        let html = "<p><strong>Anchors:</strong></p><p>Abby &amp; Otto</p><p><strong>Package:</strong></p>"
            + "<p>Club Fair</p><p><br></p><p><strong>Show Director:</strong></p><p><br></p>"
            + "<p><strong>Show Manager:</strong></p><p>Sage</p>"
        let parsed = DayContent.parse(html)
        XCTAssertEqual(parsed.sections.map(\.heading), ["Anchors", "Package", "Show Director", "Show Manager"])
        XCTAssertEqual(parsed.sections[0].names, ["Abby", "Otto"])
        XCTAssertEqual(parsed.sections[1].lines, ["Club Fair"])
        XCTAssertTrue(parsed.sections[1].names.isEmpty, "package lines are not people")
        XCTAssertEqual(parsed.sections[2].lines, [])
        XCTAssertEqual(parsed.sections[3].names, ["Sage"])
    }

    func testSameLineValuesAliasesNotesAndCrews() {
        let html = "<p>Bring the green screen</p><p>Note: wear black</p><p>SM: Rio</p>"
            + "<p><strong>PA Announcers:</strong> Juno, Kai</p><p><strong>Lunch Filmers:</strong></p><p>Abby, Otto and Sage</p>"
        let parsed = DayContent.parse(html)
        XCTAssertEqual(parsed.notes, ["Bring the green screen", "Note: wear black"], "a sentence with a colon isn't a heading")
        XCTAssertEqual(parsed.sections.map(\.heading), ["Show Manager", "PA Announcers", "Lunch Filmers"])
        XCTAssertEqual(parsed.sections[0].names, ["Rio"])
        XCTAssertEqual(parsed.sections[1].names, ["Juno", "Kai"])
        XCTAssertEqual(parsed.sections[2].names, ["Abby", "Otto", "Sage"])
    }

    func testSplitsNamesWithoutDuplicates() {
        XCTAssertEqual(DayContent.splitNames(["Abby & Otto", "otto / Sage + Rio"]), ["Abby", "Otto", "Sage", "Rio"])
        XCTAssertEqual(DayContent.decodeEntities("Rock &amp; Roll &#39;26"), "Rock & Roll '26")
    }
}

final class CalendarStoreTests: XCTestCase {
    private func month(_ json: String) throws -> CalendarMonth {
        try PortalJSON.decoder().decode(CalendarMonth.self, from: Data(json.utf8))
    }

    private let json = """
    {"month":"2026-10","canEdit":false,"canViewCastCounts":false,
     "entries":[{"date":"2026-10-07","content":"<p><strong>Anchors:</strong></p><p>Abby &amp; Otto</p>"},
                {"date":"2026-10-05","content":"<p><strong>PA Announcers:</strong></p><p>Sage</p>"}],
     "schedule":[{"date":"2026-10-05","kind":"PA","label":""},{"date":"2026-10-07","kind":"SHOW","label":""},
                 {"date":"2026-10-09","kind":"HOLIDAY","label":"Staff Development Day"},{"date":"2026-10-08","kind":"MYSTERY","label":""}],
     "queuedPackages":[{"id":"r1","groupTopic":"Gas Prices","cycleNumber":2,"custom":false,"date":"2026-10-07"}],
     "members":["Abby","Otto"],"showManagerPool":["Sage"],
     "showManagers":{"2026-10-07":{"name":"Sage","source":"rotation"}}}
    """

    func testBuildsDaysWithRotationManagerAndPackages() throws {
        let days = CalendarStore.days(from: try month(json))
        XCTAssertEqual(days.map(\.kind), [.pa, .show, .holiday, .none], "unknown kinds read as class days")
        let show = days[1]
        XCTAssertEqual(show.names(for: "Anchors"), ["Abby", "Otto"])
        XCTAssertEqual(show.names(for: "Show Manager"), ["Sage"], "the Portal's rotation fills the manager")
        XCTAssertEqual(show.packages.map(\.groupTopic), ["Gas Prices"])
        XCTAssertEqual(days[2].label, "Staff Development Day")
    }

    func testMyRolesMatchFirstNameNicknameOrFullName() throws {
        let days = CalendarStore.days(from: try month(json))
        XCTAssertEqual(CalendarRoles.mine(on: days[1], user: PortalUser.stub("student")), ["Anchor"])
        var sage = PortalUser.stub("producer")
        XCTAssertEqual(CalendarRoles.mine(on: days[1], user: sage), ["Show manager"])
        XCTAssertEqual(CalendarRoles.mine(on: days[0], user: sage), ["PA announcer"])
        sage.nickname = "Rio"
        XCTAssertEqual(CalendarRoles.mine(on: days[0], user: sage), ["PA announcer"], "first name still counts")
        XCTAssertEqual(CalendarRoles.mine(on: days[1], user: nil), [])
    }
}

final class CalendarDatesTests: XCTestCase {
    func testMonthsAndWeekdays() {
        XCTAssertEqual(CalendarDates.addMonths("2026-12", 1), "2027-01")
        XCTAssertEqual(CalendarDates.addMonths("2026-01", -1), "2025-12")
        let october = CalendarDates.weekdays(inMonth: "2026-10")
        XCTAssertEqual(october.first, "2026-10-01")
        XCTAssertEqual(october.count, 22)
        XCTAssertFalse(october.contains("2026-10-03"), "Saturday")
        XCTAssertEqual(CalendarDates.weekday("2026-10-07"), 4)
    }

    func testRelativeWords() {
        XCTAssertEqual(CalendarDates.relative("2026-10-07", today: "2026-10-07"), "Today")
        XCTAssertEqual(CalendarDates.relative("2026-10-08", today: "2026-10-07"), "Tomorrow")
        XCTAssertEqual(CalendarDates.relative("2026-10-09", today: "2026-10-07"), "Friday")
        XCTAssertEqual(CalendarDates.relative("2026-10-21", today: "2026-10-07"), "Wed, Oct 21")
    }
}

final class AnnouncementDecodingTests: XCTestCase {
    func testDecodesTheFeed() throws {
        let json = """
        [{"id":"a1","content":"Initial Cuts are due Friday.","createdAt":"2026-10-02T17:00:00.000Z",
          "author":{"id":"u1","name":"Sage"},"unread":true,"likedByMe":false,"likeCount":3,
          "mentions":[{"id":"u2","name":"Abby"}],
          "comments":[{"id":"c1","body":"Thanks!","createdAt":"2026-10-02T18:00:00Z","author":{"id":"u3","name":"Otto"}}]}]
        """
        let feed = try PortalJSON.decoder().decode([ClassAnnouncement].self, from: Data(json.utf8))
        XCTAssertEqual(feed.first?.author.name, "Sage")
        XCTAssertEqual(feed.first?.comments.first?.author.name, "Otto")
        XCTAssertTrue(feed.first?.unread == true)
    }
}

final class CalendarDeepLinkTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    func testCalendarLinks() {
        func resolve(_ string: String) -> DeepLinkMatch { DeepLink.resolve(URL(string: string)!, portal: portal) }
        XCTAssertEqual(resolve("https://portal.example.edu/master-calendar?date=2026-10-07"),
                       DeepLinkMatch(tab: .calendar, route: .calendar(.day(date: "2026-10-07"))))
        XCTAssertEqual(resolve("https://portal.example.edu/master-calendar?date=bad").route, nil)
        XCTAssertEqual(resolve("https://portal.example.edu/announcements"),
                       DeepLinkMatch(tab: .calendar, route: .calendar(.announcements)))
        XCTAssertEqual(resolve("https://portal.example.edu/show-roles").route, .calendar(.theShow))
    }
}

final class CalendarHorizonTests: XCTestCase {
    func testHorizonWords() {
        // Friday, October 2, 2026.
        XCTAssertEqual(CalendarDates.horizon("2026-10-02", today: "2026-10-02"), "Today")
        XCTAssertEqual(CalendarDates.horizon("2026-10-05", today: "2026-10-02"), "Next week")
        XCTAssertEqual(CalendarDates.horizon("2026-09-30", today: "2026-09-28"), "This week")
        XCTAssertEqual(CalendarDates.horizon("2026-10-21", today: "2026-10-02"), "Later")
    }
}
