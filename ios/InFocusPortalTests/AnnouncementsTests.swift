import XCTest
@testable import InFocusPortal

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
}

final class SlackFeedTests: XCTestCase {
    private let feedJSON = """
    {"data":{"configured":true,"error":null,"items":[
      {"id":"1","ts":"1790990000.0001","authorName":"Abby Example","authorImageUrl":null,"text":"See the rubric",
       "parts":[{"type":"text","value":"See the "},{"type":"link","href":"https://example.com/r","label":"rubric"}],
       "attachments":[{"id":"F01","title":"Rubric","prettyType":"PDF"}],
       "postedAt":"2026-10-01T16:12:00.000Z","dateLabel":"Thursday, October 1","timeLabel":"9:12 AM",
       "permalink":"https://example.slack.com/p1"},
      {"id":"2","ts":"1790903600.0002","authorName":"Otto Example","authorImageUrl":"https://example.com/a.png",
       "text":"Plain words","parts":[],"attachments":[],"postedAt":"2026-09-30T22:40:00.000Z",
       "dateLabel":"Thursday, October 1","timeLabel":"3:40 PM","permalink":"https://example.slack.com/p2"}
    ]}}
    """

    func testDecodesPostsLinksAndAttachments() throws {
        let feed = try decode(SlackFeed.self, feedJSON)
        XCTAssertTrue(feed.configured)
        XCTAssertEqual(feed.items[0].parts, [.text("See the "), .link(href: "https://example.com/r", label: "rubric")])
        XCTAssertEqual(feed.items[0].attachments.first?.prettyType, "PDF")
        XCTAssertEqual(feed.items[1].bodyParts, [.text("Plain words")], "raw text stands in when Slack sent no parts")
        XCTAssertGreaterThan(feed.items[0].sortKey, feed.items[1].sortKey)
    }

    func testOnlyWebLinksBecomeTappable() {
        let text = SlackText.attributed([.text("Go "), .link(href: "https://example.com", label: "here"),
                                         .text(" or "), .link(href: "javascript:alert(1)", label: "there")])
        XCTAssertEqual(String(text.characters), "Go here or there")
        let links = text.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.com")!])
    }

    func testInitialsAndDays() throws {
        XCTAssertEqual(SlackText.initials("Abby Example"), "AE")
        XCTAssertEqual(SlackText.initials("  "), "IF")
        let feed = try decode(SlackFeed.self, feedJSON)
        let days = AnnouncementDays.group(feed.items)
        XCTAssertEqual(days.map(\.label), ["Thursday, October 1"])
        XCTAssertEqual(days[0].posts.count, 2)
    }
}

@MainActor
final class AnnouncementsStoreTests: XCTestCase {
    private func api(_ stamps: [String]) -> AnnouncementsAPI {
        var api = AnnouncementsAPI.stub
        let posts = stamps.map { ts in
            SlackPost(id: ts, ts: ts, authorName: "Sage Example", authorImageUrl: nil, text: "Hi", parts: [],
                      attachments: [], postedAt: "", dateLabel: "Today", timeLabel: "9:00 AM", permalink: "")
        }
        api.slackFeed = { SlackFeed(configured: true, items: posts, error: nil) }
        return api
    }

    func testUnreadMeansNewerThanTheLastPostSeenOnThisPhone() async {
        let defaults = UserDefaults(suiteName: "AnnouncementsStoreTests")!
        defaults.removePersistentDomain(forName: "AnnouncementsStoreTests")
        let store = AnnouncementsStore(defaults: defaults)
        store.reset(for: "abby@example.edu")
        await store.load(api: api(["100.0", "90.0"]))
        XCTAssertEqual(store.unreadCount, 0, "the first load only sets the mark")

        await store.load(api: api(["120.0", "110.0", "100.0"]), force: true)
        XCTAssertEqual(store.unreadCount, 2)
        store.markAllSeen()
        XCTAssertEqual(store.unreadCount, 0)

        let other = AnnouncementsStore(defaults: defaults)
        other.reset(for: "abby@example.edu")
        XCTAssertEqual(other.lastSeen, 120, "the mark survives relaunch")
        other.reset(for: "otto@example.edu")
        XCTAssertEqual(other.lastSeen, 0, "each account has its own")
    }
}

final class SubmittedTests: XCTestCase {
    private let boardJSON = """
    {"data":{"canDelete":true,"canInvite":false,"collegeVisitsUrl":"https://example.com/sheet",
     "retrievedAt":"2026-10-02T15:00:00.000Z","total":2,"airToday":1,"airTomorrow":0,
     "buckets":[{"id":"today","title":"Air today","defaultOpen":true,"copyText":"A\\n\\nB","entries":[
       {"id":"a","announcement":"A","copyText":"A","destination":"InFocus only","submitterRole":"PALY Student",
        "name":"Abby Example","email":"abby@example.edu","isPermanent":false,"startDate":"2026-10-01",
        "endDate":"2026-10-05","submittedAt":"2026-09-28T17:30:00.000Z","mediaLink":"https://example.com/f","moreInfo":"Room 101"},
       {"id":"b","announcement":"B","copyText":"B","destination":"Both","submitterRole":"","name":"","email":"",
        "isPermanent":true,"startDate":"","endDate":"","submittedAt":"","mediaLink":"","moreInfo":""}]}]}}
    """

    func testDecodesTheGroupedBoard() throws {
        let board = try decode(SubmittedBoard.self, boardJSON)
        XCTAssertEqual(board.buckets.map(\.title), ["Air today"])
        XCTAssertEqual(board.buckets[0].copyText, "A\n\nB")
        XCTAssertFalse(board.canInvite)
    }

    func testDeletingTheLastEntryDropsTheSection() throws {
        let board = try decode(SubmittedBoard.self, boardJSON)
        let one = SubmittedModel.removing("a", from: board)
        XCTAssertEqual(one.total, 1)
        XCTAssertEqual(one.buckets[0].entries.map(\.id), ["b"])
        XCTAssertTrue(SubmittedModel.removing("b", from: one).buckets.isEmpty)
    }

    func testDatesAndLinksReadLikeTheWeb() throws {
        let board = try decode(SubmittedBoard.self, boardJSON)
        XCTAssertEqual(SubmittedDates.day("2026-10-03"), "Sat, Oct 3")
        XCTAssertEqual(SubmittedDates.day("Next Friday"), "Next Friday", "old sheet rows show as written")
        XCTAssertEqual(SubmittedDates.day(""), "Not set")
        XCTAssertEqual(SubmittedDates.range(board.buckets[0].entries[1]), "Permanent")
        XCTAssertEqual(SubmittedDates.range(board.buckets[0].entries[0]), "Thu, Oct 1 – Mon, Oct 5")
        XCTAssertEqual(SubmittedDates.submitted(""), "Unknown time")
        XCTAssertNotNil(SubmittedDates.link(" https://example.com/f "))
        XCTAssertNil(SubmittedDates.link("Room 101"))
    }
}

@MainActor
final class PAEditorTests: XCTestCase {
    func testDecodesThePage() throws {
        let page = try decode(PAPage.self, """
        {"data":{"date":"2026-10-05","dateLabel":"Monday, October 5th, 2026","timeLabel":"Start of second period",
         "announcers":["Abby Example"],"canEdit":true,"autofill":{"status":"warning","message":"Check names"},
         "script":{"content":"Hello","version":3}}}
        """)
        XCTAssertEqual(page.script?.version, 3)
        XCTAssertEqual(page.autofill?.message, "Check names")
        XCTAssertEqual(PAText.announcer(page.announcers, at: 0), "Abby Example")
        XCTAssertEqual(PAText.announcer(page.announcers, at: 1), "Not assigned yet")
    }

    func testEditsSaveWithTheVersionAndRefreshWaitsForThem() async {
        var api = AnnouncementsAPI.stub
        let sent = SentBox()
        api.savePA = { date, content, version in
            await sent.set(content, version)
            return AnnouncementsStubData.pa(date: date, content: content, version: version + 1)
        }
        let model = PAEditorModel()
        await model.load(api: api)
        XCTAssertFalse(model.dirty)
        XCTAssertEqual(model.statusText, "Shared script")

        model.draft += "\nOne more line."
        XCTAssertTrue(model.dirty)
        XCTAssertFalse(model.canRefresh, "refreshing would lose edits")
        XCTAssertEqual(model.statusText, "Unsaved changes")

        await model.save(api: api)
        let saved = await sent.value
        XCTAssertEqual(saved?.version, 3)
        XCTAssertFalse(model.dirty)
        XCTAssertEqual(model.page?.script?.version, 4)
        XCTAssertEqual(model.statusText, "Saved")
    }

    func testBlankScriptsCantBeSavedAndDiscardRestores() async {
        let model = PAEditorModel()
        await model.load(api: .stub)
        model.draft = "   "
        XCTAssertFalse(model.canSave)
        model.discard()
        XCTAssertEqual(model.draft, AnnouncementsStubData.paScript)
    }

    func testShowsThePortalsOwnWordsForConflictsAndEmptyRegeneration() async {
        var api = AnnouncementsAPI.stub
        api.savePA = { _, _, _ in throw PortalError.server(status: 409, message: "The script changed since you opened it.") }
        api.regeneratePA = { _, _ in throw PortalError.server(status: 503, message: "No announcements could be loaded.") }
        let model = PAEditorModel()
        await model.load(api: api)
        model.draft = "Edited"
        await model.save(api: api)
        XCTAssertEqual(model.error, "The script changed since you opened it.")
        XCTAssertTrue(model.dirty, "the draft stays")
        await model.regenerate(api: api)
        XCTAssertEqual(model.error, "No announcements could be loaded.")
    }
}

private actor SentBox {
    var value: (content: String, version: Int)?
    func set(_ content: String, _ version: Int) { value = (content, version) }
}
