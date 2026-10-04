import XCTest
@testable import InFocusPortal

final class MeetingsModelTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testDecodesTheListAndToleratesMissingExtras() throws {
        let json = """
        {"live": [{"id": "m1", "title": "Producer meeting", "startsAt": "2026-10-05T04:15:00.000Z",
                   "durationMinutes": 60, "status": "LIVE", "access": "OPEN", "inviteeCount": 0,
                   "joinOpensAt": "2026-10-05T04:10:00.000Z", "isHost": true, "canEdit": true, "notesStatus": "RECORDING",
                   "seriesKey": "producers", "participantCount": 3}],
         "upcoming": [{"id": "m2", "title": "Rundown", "startsAt": "2026-10-06T04:15:00Z", "status": "SCHEDULED",
                       "access": "INVITE_ONLY"}],
         "past": [], "canCreateInviteOnly": true}
        """
        let list = try PortalJSON.decoder().decode(MeetingsList.self, from: Data(json.utf8))
        XCTAssertEqual(list.live.first?.joinOpensAt, date("2026-10-05T04:10:00Z"))
        XCTAssertTrue(list.live.first?.isLive == true)
        let rundown = try XCTUnwrap(list.upcoming.first)
        XCTAssertTrue(rundown.isInviteOnly)
        XCTAssertNil(rundown.joinOpensAt)
        XCTAssertEqual(rundown.durationMinutes, 60)
        XCTAssertEqual(rundown.opensAt, date("2026-10-06T04:10:00Z")) // 5 minutes before by default
        XCTAssertTrue(list.canCreateInviteOnly)
    }

    func testJoinWindow() {
        let start = date("2026-10-05T04:15:00Z")
        let opens = date("2026-10-05T04:10:00Z")
        let meeting = MeetingSummary(id: "m", title: "T", startsAt: start, joinOpensAt: opens)
        XCTAssertEqual(meeting.joinState(now: opens.addingTimeInterval(-1)), .opensAt(opens))
        XCTAssertEqual(meeting.joinState(now: opens), .open)
        XCTAssertEqual(meeting.joinState(now: start.addingTimeInterval(600)), .open)
        let live = MeetingSummary(id: "m", title: "T", startsAt: start.addingTimeInterval(3600), status: "LIVE")
        XCTAssertEqual(live.joinState(now: start), .open) // live is always joinable
        for status in ["ENDED", "CANCELED"] {
            XCTAssertEqual(MeetingSummary(id: "m", title: "T", startsAt: start, status: status).joinState(now: start), .closed)
        }
    }

    func testOpensAtLabelIsPacificTime() {
        let label = MeetingDates.clock(date("2026-10-05T04:10:00Z")).replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(label, "9:10 PM") // iOS puts a narrow no-break space before AM/PM
    }

    func testGroupsUpcomingByPacificDay() {
        let now = date("2026-10-04T19:00:00Z") // Sunday noon Pacific
        let meetings = [
            MeetingSummary(id: "c", title: "Wed", startsAt: date("2026-10-08T04:15:00Z")), // Wed 9:15 PM PDT
            MeetingSummary(id: "a", title: "Sun", startsAt: date("2026-10-05T04:15:00Z")), // Sun 9:15 PM PDT (Mon UTC)
            MeetingSummary(id: "b", title: "Mon", startsAt: date("2026-10-06T04:15:00Z")), // Mon 9:15 PM PDT
            MeetingSummary(id: "a2", title: "Sun late", startsAt: date("2026-10-05T06:30:00Z")), // Sun 11:30 PM PDT
        ]
        let days = MeetingDates.groupByDay(meetings, now: now)
        XCTAssertEqual(days.map(\.heading), ["Today", "Tomorrow", "Wednesday, October 7"])
        XCTAssertEqual(days.map { $0.meetings.map(\.id) }, [["a", "a2"], ["b"], ["c"]])
        XCTAssertEqual(days.first?.id, "2026-10-04")
    }

    func testSampleMeetingsCoverEverySection() {
        let list = MeetingsService.sampleList()
        XCTAssertFalse(list.live.isEmpty)
        XCTAssertTrue(list.upcoming.contains { $0.isInviteOnly })
        XCTAssertFalse(list.past.isEmpty)
    }
}

final class MeetingsDeepLinkTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func resolve(_ string: String) -> DeepLinkMatch {
        DeepLink.resolve(URL(string: string)!, portal: portal)
    }

    func testMeetLinksOpenTheCallAndTheListOpensInMore() {
        XCTAssertEqual(resolve("https://portal.example.edu/meet/cmeet123"), DeepLinkMatch(tab: nil, route: .meetings(.call(id: "cmeet123"))))
        XCTAssertEqual(resolve("https://portal.example.edu/meetings"), DeepLinkMatch(tab: .more, route: .meetings(.home)))
        let notes = URL(string: "https://portal.example.edu/meetings/cmeet123")!
        XCTAssertEqual(resolve(notes.absoluteString).route, .portal(PortalPage(url: notes))) // notes page: web view
        XCTAssertEqual(resolve("https://portal.example.edu/meet").route,
                       .portal(PortalPage(url: URL(string: "https://portal.example.edu/meet")!)))
    }

    func testRelativePushURLResolvesAgainstThePortal() {
        let url = NotificationRouter.destination(for: ["url": "/meet/cmeet123"], portal: portal)
        XCTAssertEqual(url.absoluteString, "https://portal.example.edu/meet/cmeet123")
        XCTAssertEqual(NotificationRouter.destination(for: ["url": "//evil.test/meet/x"], portal: portal), portal)
    }

    @MainActor
    func testRouterPresentsTheCallInsteadOfPushing() {
        let router = Router()
        router.portal = portal
        router.select(.calendar)
        router.open(URL(string: "https://portal.example.edu/meet/cmeet123")!)
        XCTAssertEqual(router.activeCall, MeetingCall(id: "cmeet123"))
        XCTAssertEqual(router.selectedTab, .calendar) // stays where you were
        XCTAssertEqual(router.path(.calendar).wrappedValue, [])
        router.activeCall = nil
        router.push(.meetings(.call(id: "other")))
        XCTAssertEqual(router.activeCall, MeetingCall(id: "other"))
    }

    @MainActor
    func testSampleAppHasNoCalls() {
        let router = Router()
        router.portal = portal
        router.sampleOnly = true
        var refused = false
        router.onRefused = { refused = true }
        router.joinMeeting("cmeet123")
        XCTAssertNil(router.activeCall)
        XCTAssertTrue(refused)
    }

    func testCallURLAndLeaveDetection() {
        XCTAssertEqual(MeetingCallController.callURL(portal: portal, meetingId: "cmeet123").absoluteString,
                       "https://portal.example.edu/meet/cmeet123?app=1")
        XCTAssertTrue(MeetingCallController.isLeaveURL(URL(string: "https://portal.example.edu/meetings?left=1")!, portal: portal))
        XCTAssertFalse(MeetingCallController.isLeaveURL(URL(string: "https://portal.example.edu/meet/cmeet123?app=1")!, portal: portal))
        XCTAssertFalse(MeetingCallController.isLeaveURL(URL(string: "https://evil.test/meetings?left=1")!, portal: portal))
    }
}
