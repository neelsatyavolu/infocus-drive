import XCTest
@testable import InFocusPortal

final class CalendarCellHTMLTests: XCTestCase {
    private let show = "<p><strong>Anchors:</strong></p><p>Abby &amp; Otto</p><p><strong>Package:</strong></p>"
        + "<p><span class=\"package-pill\" data-package-id=\"p1\">Club Fair</span></p>"
        + "<p><strong>Show Director:</strong></p><p>Juno</p><p><strong>Show Manager:</strong></p><p>Sage</p>"

    func testShowDirectorChangesOnlyItsSection() {
        let next = CalendarCellHTML.setShowDirector(show, names: ["Kai"])
        XCTAssertTrue(next.contains("<p><strong>Show Director:</strong></p><p>Kai</p><p><strong>Show Manager:</strong></p><p>Sage</p>"))
        XCTAssertTrue(next.hasPrefix("<p><strong>Anchors:</strong></p><p>Abby &amp; Otto</p>"), "anchors stay")
        XCTAssertTrue(next.contains("data-package-id=\"p1\""), "package pills stay")
        XCTAssertFalse(next.contains("Juno"))
    }

    func testClearingAndMissingSections() {
        XCTAssertTrue(CalendarCellHTML.setShowDirector(show, names: []).contains("<p><strong>Show Director:</strong></p><p><br></p><p><strong>Show Manager:"))
        let fromEmpty = CalendarCellHTML.setShowDirector("", names: ["Rio"])
        XCTAssertTrue(fromEmpty.hasPrefix("<p><strong>Anchors:</strong></p>"), "an empty cell starts from the show template")
        XCTAssertTrue(fromEmpty.contains("<p><strong>Show Director:</strong></p><p>Rio</p>"))
        let missing = CalendarCellHTML.replaceSection("<p>Assembly</p>", heading: "Editors", nextHeadings: [], inner: "<p>Kai</p>")
        XCTAssertEqual(missing, "<p><strong>Editors:</strong></p><p>Kai</p><p>Assembly</p>")
    }

    func testHeadingsMatchLikeThePortal() {
        let spaced = "<p> <strong> show director: </strong> </p><p>Juno</p><p><strong>Show Manager:</strong></p>"
        XCTAssertTrue(CalendarCellHTML.setShowDirector(spaced, names: ["Kai"]).contains("</p><p>Kai</p><p><strong>Show Manager:"))
    }

    func testNamesAndNotesAreEscaped() {
        XCTAssertEqual(CalendarCellHTML.nameParagraph(["Abby", " Otto ", "Sage"]), "<p>Abby &amp; Otto</p>", "pairs keep two names")
        XCTAssertEqual(CalendarCellHTML.nameParagraph([]), "<p><br></p>")
        XCTAssertEqual(CalendarCellHTML.notes(["Spirit rally <7th>", "", "  Bring IDs "]), "<p>Spirit rally &lt;7th&gt;</p><p>Bring IDs</p>")
    }
}

final class CastEligibilityTests: XCTestCase {
    private func day(_ date: String, _ kind: DayKind, anchors: [String]) -> CalendarDay {
        CalendarDay(date: date, kind: kind, label: "",
                    roles: anchors.isEmpty ? [] : [DayContent.Section(heading: "Anchors", lines: [anchors.joined(separator: " & ")], isPeople: true)],
                    notes: [], packages: [])
    }

    func testNobodyAnchorsTwiceInAMonth() {
        let days = [day("2026-10-07", .show, anchors: ["Abby", "Otto"]), day("2026-10-09", .show, anchors: ["Sage"]),
                    day("2026-10-12", .pa, anchors: []), day("2026-11-04", .show, anchors: ["Kai"])]
        let taken = CastEligibility.monthAnchors(in: days, excluding: "2026-10-09")
        XCTAssertEqual(taken, ["abby", "otto"], "the day being edited and other months don't count")
        XCTAssertEqual(CastEligibility.anchorBlock("abby", otherSlot: "", monthAnchors: taken), .anchoredThisMonth)
        XCTAssertEqual(CastEligibility.anchorBlock("Sage", otherSlot: "sage", monthAnchors: taken), .otherSlot)
        XCTAssertNil(CastEligibility.anchorBlock("Kai", otherSlot: "Sage", monthAnchors: taken))
    }

    func testPairsListsAndOptions() {
        XCTAssertEqual(CastEligibility.pair(["Abby", "Otto"], setting: 1, to: "Kai"), ["Abby", "Kai"])
        XCTAssertEqual(CastEligibility.pair(["Abby", "Otto"], setting: 0, to: ""), ["Otto"], "clearing a slot keeps the other")
        XCTAssertEqual(CastEligibility.pair([], setting: 1, to: "Rio"), ["Rio"])
        XCTAssertEqual(CastEligibility.listBlock("kai", listed: ["Kai"]), .alreadyListed)
        XCTAssertNil(CastEligibility.pairBlock("Kai", otherSlot: ""))
        XCTAssertEqual(CastEligibility.options(["Rio", "Sage"], keeping: "Tess"), ["Tess", "Rio", "Sage"], "a manager out of the pool stays pickable")
        XCTAssertEqual(CastEligibility.options(["Rio", "Sage"], keeping: "Sage"), ["Rio", "Sage"])
    }

    func testCastCountSummary() {
        let people = [CastCount(name: "otto", anchors: 0, pa: 1), CastCount(name: "Abby", anchors: 2, pa: 0), CastCount(name: "Kai", anchors: 0, pa: 0)]
        let summary = CastCountSummary(people)
        XCTAssertEqual([summary.roster, summary.neverAnchored, summary.neverPa], [3, 2, 2])
        XCTAssertEqual(CastCountSummary.sorted(people).map(\.name), ["Abby", "Kai", "otto"])
    }
}

final class CalendarEditDecodingTests: XCTestCase {
    func testMonthWithProducerFields() throws {
        let json = """
        {"month":"2026-10","canEdit":true,"canViewCastCounts":false,"entries":[],"schedule":[{"date":"2026-10-07","kind":"SHOW","label":""}],
         "queuedPackages":[],"members":["Abby","Otto"],"showManagerPool":["Sage"],
         "showManagers":{"2026-10-07":{"name":"Sage","source":"manual"}},
         "spiritWeek":{"2026-10-07":{"theme":"Paly spirit","crewRoles":["Lunch Filmers","Editors"]}}}
        """
        let month = try PortalJSON.decoder().decode(CalendarMonth.self, from: Data(json.utf8))
        XCTAssertEqual(month.members, ["Abby", "Otto"])
        XCTAssertEqual(month.canViewCastCounts, false)
        XCTAssertTrue(month.showManagers["2026-10-07"]?.isManual == true)
        XCTAssertEqual(month.spiritWeek?["2026-10-07"]?.crewRoles, ["Lunch Filmers", "Editors"])
        XCTAssertEqual(month.replacing("2026-10-07", content: "<p>x</p>").content(of: "2026-10-07"), "<p>x</p>")
        XCTAssertTrue(month.replacing("2026-10-07", content: "").entries.isEmpty, "an empty cell is removed")
    }

    func testOlderPortalMonthStillDecodes() throws {
        let json = #"{"month":"2026-10","canEdit":false,"entries":[],"schedule":[],"queuedPackages":[],"showManagers":{"2026-10-07":{"name":"Sage"}}}"#
        let month = try PortalJSON.decoder().decode(CalendarMonth.self, from: Data(json.utf8))
        XCTAssertNil(month.members)
        XCTAssertNil(month.spiritWeek)
        XCTAssertFalse(month.showManagers["2026-10-07"]?.isManual ?? true)
    }

    func testShowOverviewAndManagerResult() throws {
        let json = """
        {"date":"2026-10-07","label":"Wednesday, Oct. 7","kind":"SHOW","mode":"random","members":["Abby","Otto"],
         "roles":["Show Director"],"anchors":["Abby"],"paAnnouncers":[],"assignments":{"Show Director":"Juno"},"confirmed":{},
         "showManager":{"name":"Sage","source":"rotation"},"showManagerPool":["Sage","Rio"],"monthAnchors":["Otto"],
         "suggestedAnchors":["Kai","Rio"],"suggestedPa":[],
         "packages":[{"id":"r1","cycleNumber":2,"groupTopic":"Club Fair","custom":false,"queuedForShowDate":"2026-10-07","members":["Abby"]}],
         "teleprompterDocId":null,"teleprompterHref":"/teleprompter?showDate=2026-10-07",
         "upcomingShows":[{"date":"2026-10-07","label":"Wed, Oct. 7","mode":"random","packageCount":1,"showManager":"Sage"}]}
        """
        let show = try PortalJSON.decoder().decode(ShowOverview.self, from: Data(json.utf8))
        XCTAssertEqual(show.monthAnchors, ["Otto"])
        XCTAssertEqual(show.packages.first?.members, ["Abby"])
        XCTAssertNil(show.teleprompterDocId)
        let manager = try PortalJSON.decoder().decode(ShowManagerResult.self, from: Data(#"{"date":"2026-10-07","content":"","pool":["Sage"],"name":"Rio","source":"manual"}"#.utf8))
        XCTAssertEqual(manager.name, "Rio")
    }
}

@MainActor
final class CalendarDayEditorTests: XCTestCase {
    private actor Calls {
        var anchors: [[String]] = []
        var cells: [String] = []
        func record(_ names: [String]) { anchors.append(names) }
        func save(_ content: String) { cells.append(content) }
    }

    private func month(_ content: String) -> CalendarMonth {
        CalendarMonth(month: "2026-10", canEdit: true, entries: [.init(date: "2026-10-07", content: content)],
                      schedule: [.init(date: "2026-10-07", kind: .show, label: "")], queuedPackages: [], showManagers: [:])
    }

    private func read(_ content: String) -> CalendarAPI {
        var api = CalendarAPI.stub
        let fixed = month(content)
        api.month = { _ in fixed }
        return api
    }

    func testSavedAnchorsShowAndReload() async {
        let calls = Calls()
        var edit = CalendarEditAPI.stub
        edit.setAnchors = { _, names, source in
            await calls.record(names + [source])
            return "<p><strong>Anchors:</strong></p><p>Kai &amp; Rio</p>"
        }
        let store = CalendarStore()
        let editor = CalendarDayEditor(date: "2026-10-07", edit: edit, read: read("<p><strong>Anchors:</strong></p><p>Kai &amp; Rio</p>"), store: store)
        await editor.setAnchors(["Kai", "Rio"])
        let recorded = await calls.anchors
        XCTAssertEqual(recorded, [["Kai", "Rio", "manual"]])
        XCTAssertNil(editor.error)
        XCTAssertEqual(store.day("2026-10-07")?.names(for: "Anchors"), ["Kai", "Rio"])
    }

    func testRandomizeWithNobodyLeftExplains() async {
        var edit = CalendarEditAPI.stub
        edit.suggestAnchors = { _ in [] }
        let editor = CalendarDayEditor(date: "2026-10-07", edit: edit, read: read(""), store: CalendarStore())
        await editor.randomizeAnchors()
        XCTAssertEqual(editor.error, "No eligible anchors left this month.")
        XCTAssertFalse(editor.busy)
    }

    func testShowDirectorEditsTheFreshCell() async {
        let calls = Calls()
        var edit = CalendarEditAPI.stub
        edit.saveCell = { _, content in await calls.save(content); return content }
        let editor = CalendarDayEditor(date: "2026-10-07", edit: edit,
                                       read: read("<p><strong>Anchors:</strong></p><p>Abby</p><p><strong>Show Director:</strong></p><p>Juno</p>"),
                                       store: CalendarStore())
        await editor.setShowDirector(["Kai"])
        let saved = await calls.cells
        XCTAssertEqual(saved, ["<p><strong>Anchors:</strong></p><p>Abby</p><p><strong>Show Director:</strong></p><p>Kai</p>"],
                       "only the director changes, starting from the Portal's current cell")
        XCTAssertNil(editor.error)
    }
}
