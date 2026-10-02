import XCTest
@testable import InFocusPortal

final class RosterDecodingTests: XCTestCase {
    private let json = """
    {"data":{"canEdit":true,"canAssignProducer":true,"activeCycleNumber":2,
      "cycles":[{"cycleNumber":2,"focus":"Features","dates":{"pitching":"2026-09-30T00:00:00.000Z","proofOfContact":null,
        "aRollBRoll":null,"initialCut":null,"finalCut":"2026-11-03T00:00:00.000Z"}}],
      "producers":[{"userId":"otto","name":"Otto Example","email":"otto@example.edu"}],
      "executives":[{"userId":"sage","name":"Sage Example","email":"sage@example.edu"}],
      "previousTeammatesByUser":{"abby":["wren"]},
      "rows":[{"id":"r1","groupTopic":"Water polo","groupMembers":"@[Abby](abby), @[Wren](wren)","groupType":"",
        "category":"NEWS","memberUserIds":["abby","wren"],
        "members":[{"userId":"abby","name":"Abby Example","email":null},{"userId":"wren","name":"Wren Example","email":null}],
        "assignedProducerUserId":"otto","assignedProducer":{"userId":"otto","name":"Otto Example","email":null},
        "assignedExecutiveProducerUserId":null,"assignedExecutiveProducer":null,
        "pitching":true,"proofOfContact":true,"aRollBRoll":false,"initialCut":false,"finalCut":false,"extension":false,
        "extensionDays":1.5,"stageNotes":{"pitching":"Good"},"initialCutMediaItemId":"media-1","queuedForAir":false,
        "possibleInterviews":"Coach","possibleIdeas":"","notes":"","packageOfCycleAt":null}]}}
    """

    private func payload() throws -> RosterPayload {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<RosterPayload>.self, from: Data(json.utf8)).data
    }

    func testDecodesTheRoster() throws {
        let roster = try payload()
        XCTAssertTrue(roster.canEdit)
        XCTAssertEqual(roster.activeCycleNumber, 2)
        let row = try XCTUnwrap(roster.rows.first)
        XCTAssertEqual(row.id, "r1")
        XCTAssertEqual(row.topic, "Water polo")
        XCTAssertEqual(row.members.map(\.name), ["Abby Example", "Wren Example"])
        XCTAssertEqual(RosterStage.done(row), [.pitching, .proofOfContact])
        XCTAssertEqual(RosterStage.current(row), .aRollBRoll)
        XCTAssertTrue(row.hasExtension)
        XCTAssertEqual(RosterLogic.assignedLabel(row, producers: roster.producers, executives: roster.executives), "Otto Example · AP")
    }

    /// The save replaces the whole cycle: fields the app doesn't edit must go back unchanged.
    func testSavingKeepsFieldsTheAppDoesNotEdit() throws {
        var row = try XCTUnwrap(try payload().rows.first).raw
        row["groupTopic"] = .string("Water polo's season")
        let body = try JSONEncoder().encode(RosterSave(cycleNumber: 2, rows: [row]))
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let saved = try XCTUnwrap((sent["rows"] as? [[String: Any]])?.first)
        XCTAssertEqual(saved["groupTopic"] as? String, "Water polo's season")
        XCTAssertEqual(saved["category"] as? String, "NEWS")
        XCTAssertEqual(saved["pitching"] as? Bool, true)
        XCTAssertEqual(saved["initialCutMediaItemId"] as? String, "media-1")
        XCTAssertEqual((saved["stageNotes"] as? [String: String])?["pitching"], "Good")
        XCTAssertEqual(saved["extensionDays"] as? Double, 1.5)
        XCTAssertTrue(saved["assignedExecutiveProducerUserId"] is NSNull)
    }
}

final class RosterLogicTests: XCTestCase {
    private let people: [String: RosterPerson] = [
        "abby": RosterPerson(id: "abby", email: "abby@example.edu", name: "Abby Example", nickname: "Abs"),
        "otto": RosterPerson(id: "otto", email: "otto@example.edu", name: nil, nickname: nil),
    ]

    func testOneAssignedProducer() {
        var row = RosterLogic.newRow()
        RosterLogic.assign(&row, to: "sage", executiveIds: ["sage"])
        XCTAssertEqual(row["assignedExecutiveProducerUserId"], .string("sage"))
        XCTAssertEqual(row["assignedProducerUserId"], .null)
        RosterLogic.assign(&row, to: "otto", executiveIds: ["sage"])
        XCTAssertEqual(row["assignedProducerUserId"], .string("otto"))
        XCTAssertEqual(row["assignedExecutiveProducerUserId"], .null)
        RosterLogic.assign(&row, to: nil, executiveIds: ["sage"])
        XCTAssertEqual(row["assignedProducerUserId"], .null)
    }

    func testMembersTextUsesFirstNames() {
        XCTAssertEqual(RosterLogic.groupMembersText(["abby", "otto", "missing"], people: people), "@[Abby](abby), @[otto](otto)")
        var row = RosterLogic.newRow()
        RosterLogic.setMembers(&row, ids: ["abby", "abby", "otto"], people: people)
        XCTAssertEqual(RosterRow(raw: row).memberUserIds, ["abby", "otto"])
        XCTAssertEqual(RosterRow(raw: row).members.first?.name, "Abs")
    }

    func testSameGroupLastCycle() {
        let previous = ["abby": ["wren", "kai"], "wren": ["abby"]]
        let pairs = RosterLogic.repeatedPairs(["abby", "wren", "otto"], previous: previous)
        XCTAssertEqual(pairs.map(\.userId), ["abby", "wren"])
        XCTAssertEqual(pairs.first?.with, ["wren"])
        XCTAssertEqual(RosterLogic.lastCycleGroupmates(of: "kai", among: ["abby", "otto"], previous: ["kai": ["abby"]]), ["abby"])
    }

    func testStatsAndAssignableOrder() {
        var assigned = RosterLogic.newRow()
        RosterLogic.assign(&assigned, to: "otto", executiveIds: [])
        var members = RosterLogic.newRow()
        RosterLogic.setMembers(&members, ids: ["abby"], people: people)
        XCTAssertEqual(RosterLogic.stats([RosterRow(raw: assigned), RosterRow(raw: members), RosterRow(raw: RosterLogic.newRow())]),
                       .init(total: 3, withMembers: 1, withAssigned: 1))
        let both = AssignablePerson(userId: "sage", name: "Sage", email: nil)
        let options = RosterLogic.assignable(producers: [AssignablePerson(userId: "otto", name: "Otto", email: nil), both],
                                             executives: [both])
        XCTAssertEqual(options.map(\.person.userId), ["sage", "otto"])
        XCTAssertEqual(options.map(\.isExecutive), [true, false])
    }
}

final class CycleScheduleTests: XCTestCase {
    private func date(_ iso: String) -> Date { PortalJSON.date(from: iso)! }

    func testStagesCloseAt1159PMPacific() {
        // Oct 7, 2026 is PDT (UTC-7): closes 06:59:59.999Z on Oct 8.
        XCTAssertFalse(CycleSchedule.passed("2026-10-07", stage: .initialCut, now: date("2026-10-08T06:59:00Z")))
        XCTAssertTrue(CycleSchedule.passed("2026-10-07", stage: .initialCut, now: date("2026-10-08T07:00:00Z")))
        // Dec 11, 2026 is PST (UTC-8).
        XCTAssertFalse(CycleSchedule.passed("2026-12-11", stage: .finalCut, now: date("2026-12-12T07:30:00Z")))
        XCTAssertTrue(CycleSchedule.passed("2026-12-11", stage: .finalCut, now: date("2026-12-12T08:00:01Z")))
        // The one-off Final Cut extension (2 AM PDT Sep 30).
        XCTAssertFalse(CycleSchedule.passed("2026-09-29", stage: .finalCut, now: date("2026-09-30T08:30:00Z")))
        XCTAssertTrue(CycleSchedule.passed("2026-09-29", stage: .initialCut, now: date("2026-09-30T08:30:00Z")))
        XCTAssertFalse(CycleSchedule.passed(nil, stage: .finalCut, now: Date()))
    }

    func testStatus() {
        let now = date("2026-10-07T18:00:00Z") // 11 AM PDT Oct 7
        XCTAssertEqual(CycleSchedule.status("2026-10-07", stage: .pitching, now: now), .dueToday)
        XCTAssertEqual(CycleSchedule.status("2026-10-10", stage: .pitching, now: now), .inDays(3))
        XCTAssertEqual(CycleSchedule.status("2026-10-06", stage: .pitching, now: now), .completed)
        XCTAssertEqual(CycleSchedule.status(nil, stage: .pitching, now: now), .tbd)
        XCTAssertEqual(CycleSchedule.status("2026-02-30", stage: .pitching, now: now), .tbd)
    }

    func testSectionsAndNextStage() {
        let one = CycleDates(cycleNumber: 1, focus: nil, pitchingDate: "2026-08-25", proofOfContactDate: "2026-09-02",
                             aRollBRollDate: nil, initialCutDate: nil, finalCutDate: "2026-09-25")
        let two = CycleDates(cycleNumber: 2, focus: nil, pitchingDate: "2026-09-30", proofOfContactDate: "2026-10-07",
                             aRollBRollDate: nil, initialCutDate: "2026-10-27", finalCutDate: "2026-11-03")
        let three = CycleDates(cycleNumber: 3, focus: nil, pitchingDate: nil, proofOfContactDate: nil,
                               aRollBRollDate: nil, initialCutDate: nil, finalCutDate: nil)
        let now = date("2026-10-07T18:00:00Z")
        let ordered = CycleSchedule.ordered([three, one, two], now: now)
        XCTAssertEqual(ordered.map(\.cycle.cycleNumber), [2, 3, 1])
        XCTAssertEqual(ordered.map(\.section), [.active, .planned, .closed])
        XCTAssertEqual(CycleSchedule.nextStage(two, now: now)?.stage, .proofOfContact)
        XCTAssertNil(CycleSchedule.nextStage(three, now: now))
        XCTAssertTrue(CycleSchedule.name(two).hasPrefix("Cycle 2 · "))
        XCTAssertEqual(CycleSchedule.key(for: date("2026-10-08T03:00:00Z")), "2026-10-07") // 8 PM PDT
    }

    func testCycleSaveSendsNullForTBD() throws {
        let cycle = CycleDates(cycleNumber: 3, focus: nil, pitchingDate: "2026-11-05", proofOfContactDate: nil,
                               aRollBRollDate: nil, initialCutDate: nil, finalCutDate: nil)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(cycle)) as? [String: Any])
        XCTAssertEqual(sent["pitchingDate"] as? String, "2026-11-05")
        XCTAssertTrue(sent["finalCutDate"] is NSNull)
        XCTAssertEqual(sent["focus"] as? String, "")
    }
}

final class PackageCyclesLinkTests: XCTestCase {
    func testDeepLinks() {
        XCTAssertEqual(PackageCyclesRoute.deepLink(["package-progress"], [])?.route, .packageCycles(.home))
        XCTAssertEqual(PackageCyclesRoute.deepLink(["package-progress"], [URLQueryItem(name: "cycle", value: "3")])?.route,
                       .packageCycles(.cycle(number: 3)))
        XCTAssertEqual(PackageCyclesRoute.deepLink(["package-progress"], [URLQueryItem(name: "cycle", value: "99")])?.route,
                       .packageCycles(.home))
        XCTAssertEqual(PackageCyclesRoute.deepLink(["package-cycles"], [])?.tab, .more)
        XCTAssertNil(PackageCyclesRoute.deepLink(["groups"], []))
    }
}

/// The store against the stub: every edit re-reads the cycle and changes only that group.
@MainActor
final class RosterStoreTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.set("producer", forKey: "InFocusStubSession")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "InFocusStubSession")
    }

    func testEditsAddAndDelete() async throws {
        let client = PortalClient(portal: URL(string: "https://portal.example.edu")!, cookies: { [] })
        let store = RosterStore(service: .resolve(client), cycle: 3)
        await store.load()
        XCTAssertEqual(store.roster?.rows.count, 0)
        let added = await store.addGroup()
        let id = try XCTUnwrap(added)
        let topicSaved = await store.setTopic(id, "Homecoming parade")
        XCTAssertTrue(topicSaved)
        XCTAssertEqual(store.row(id)?.topic, "Homecoming parade")
        let assigned = await store.assign(id, to: "sage")
        XCTAssertTrue(assigned)
        XCTAssertEqual(store.row(id)?.assignedExecutiveUserId, "sage")
        let deleted = await store.delete(id)
        XCTAssertTrue(deleted)
        XCTAssertNil(store.row(id))
        XCTAssertNil(store.errorMessage)
    }
}
