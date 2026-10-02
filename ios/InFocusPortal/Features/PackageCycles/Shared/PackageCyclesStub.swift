import Foundation

/// Fictional rosters, cycles and winners for `-InFocusStubSession` screenshots. Edits stick
/// for the session so saves, moves and deletes can be shown. Placeholder names only.
actor PackageCyclesStub {
    static let shared = PackageCyclesStub()

    static let people: [RosterPerson] = [
        ("abby", "Abby Example"), ("otto", "Otto Example"), ("sage", "Sage Example"), ("rio", "Rio Example"),
        ("juno", "Juno Example"), ("kai", "Kai Example"), ("wren", "Wren Example"), ("milo", "Milo Example"),
        ("ivy", "Ivy Example"), ("nova", "Nova Example"),
    ].map { RosterPerson(id: $0.0, email: "\($0.0)@example.edu", name: $0.1, nickname: nil) }

    static let producers = [AssignablePerson(userId: "otto", name: "Otto Example", email: "otto@example.edu"),
                            AssignablePerson(userId: "juno", name: "Juno Example", email: "juno@example.edu")]
    static let executives = [AssignablePerson(userId: "sage", name: "Sage Example", email: "sage@example.edu"),
                             AssignablePerson(userId: "kai", name: "Kai Example", email: "kai@example.edu")]

    private var rowsByCycle: [Int: [[String: JSONValue]]]
    private var cycleDates: [CycleDates]
    private var count = 3
    private var nextId = 100

    init() {
        let byId = Dictionary(uniqueKeysWithValues: Self.people.map { ($0.id, $0) })
        func row(_ id: String, _ topic: String, members: [String], ap: String? = nil, ep: String? = nil,
                 done: Int, extras: [String: JSONValue] = [:]) -> [String: JSONValue] {
            var row = RosterLogic.newRow()
            row["id"] = .string(id)
            row["groupTopic"] = .string(topic)
            RosterLogic.setMembers(&row, ids: members, people: byId)
            if let ap { RosterLogic.assign(&row, to: ap, executiveIds: []) }
            if let ep { RosterLogic.assign(&row, to: ep, executiveIds: [ep]) }
            for stage in RosterStage.allCases.prefix(done) { row[stage.rowKey] = .bool(true) }
            row["possibleInterviews"] = .string(id == "r1" ? "Coach (athletics office), two team captains" : "")
            return row.merging(extras) { $1 }
        }
        rowsByCycle = [
            1: [row("p1", "School lunch prices", members: ["abby", "rio"], ap: "otto", done: 5,
                    extras: ["packageOfCycleAt": .string("2026-09-30T18:00:00.000Z"), "queuedForAir": .bool(true)]),
                row("p2", "Library makerspace", members: ["wren", "milo"], ep: "sage", done: 5)],
            2: [row("r1", "Water polo's undefeated season", members: ["abby", "wren", "ivy"], ap: "otto", done: 3,
                    extras: ["extensionDays": .number(1.5)]),
                row("r2", "Gas prices and student drivers", members: ["rio", "milo"], ep: "sage", done: 2),
                row("r3", "Puppy yoga in the quad", members: ["nova"], done: 1),
                row("r4", "", members: [], done: 0)],
            3: [],
        ]
        cycleDates = [
            CycleDates(cycleNumber: 1, focus: "News", pitchingDate: "2026-08-25", proofOfContactDate: "2026-09-02",
                       aRollBRollDate: "2026-09-11", initialCutDate: "2026-09-22", finalCutDate: "2026-09-29"),
            CycleDates(cycleNumber: 2, focus: "Features", pitchingDate: "2026-09-30", proofOfContactDate: "2026-10-07",
                       aRollBRollDate: "2026-10-16", initialCutDate: "2026-10-27", finalCutDate: "2026-11-03"),
            CycleDates(cycleNumber: 3, focus: "", pitchingDate: "2026-11-05", proofOfContactDate: "2026-11-13",
                       aRollBRollDate: nil, initialCutDate: nil, finalCutDate: "2026-12-11"),
        ]
    }

    private var isEditor: Bool {
        UserDefaults.standard.string(forKey: "InFocusStubSession") != "associate"
    }

    func roster(cycle: Int?) throws -> RosterPayload {
        let number = cycle ?? 2
        let previous = Dictionary(grouping: (rowsByCycle[number - 1] ?? []).flatMap { row -> [(String, [String])] in
            let ids = row["memberUserIds"]?.array?.compactMap(\.string) ?? []
            return ids.map { id in (id, ids.filter { $0 != id }) }
        }, by: \.0).mapValues { $0.flatMap(\.1) }
        return RosterPayload(
            canEdit: isEditor, canAssignProducer: isEditor, activeCycleNumber: number,
            cycles: cycleDates.prefix(count).map { dates in
                RosterCycle(cycleNumber: dates.cycleNumber, focus: dates.focus, dates: .init(
                    pitching: CycleSchedule.closesAt(dates.pitchingDate ?? "", stage: .pitching),
                    proofOfContact: nil, aRollBRoll: nil, initialCut: nil,
                    finalCut: CycleSchedule.closesAt(dates.finalCutDate ?? "", stage: .finalCut)))
            },
            producers: Self.producers, executives: Self.executives, previousTeammatesByUser: previous,
            rows: (rowsByCycle[number] ?? []).map(RosterRow.init(raw:)))
    }

    func save(cycle: Int, rows: [[String: JSONValue]]) {
        rowsByCycle[cycle] = rows.map { row in
            guard row["id"]?.string == nil else { return row }
            nextId += 1
            return row.merging(["id": .string("new\(nextId)")]) { $1 }
        }
    }

    func move(rowId: String, to cycle: Int) {
        for (number, rows) in rowsByCycle {
            guard let row = rows.first(where: { $0["id"]?.string == rowId }) else { continue }
            rowsByCycle[number] = rows.filter { $0["id"]?.string != rowId }
            rowsByCycle[cycle, default: []].append(row)
            return
        }
    }

    func cycles() -> CyclesPayload {
        CyclesPayload(canEdit: true, canEditCycleCount: isEditor, cyclesPerSemester: count,
                      cycles: Array(cycleDates.prefix(count)))
    }

    func saveCycle(_ cycle: CycleDates) {
        cycleDates = cycleDates.map { $0.cycleNumber == cycle.cycleNumber ? cycle : $0 }
    }

    func setCount(_ next: Int) {
        while cycleDates.count < next { cycleDates.append(CycleDates(cycleNumber: cycleDates.count + 1)) }
        count = next
    }

    static let winners = WinnersPayload(viewerUserId: "abby", canDownloadAll: true, winners: [
        CycleWinner(rowId: "p1", cycleNumber: 1, topic: "School lunch prices", headline: "What a school lunch really costs",
                    awardedAt: Date(timeIntervalSince1970: 1_790_000_000),
                    members: [.init(userId: "abby", name: "Abby Example"), .init(userId: "rio", name: "Rio Example")]),
    ])
}

extension CycleDates {
    init(cycleNumber: Int) {
        self.init(cycleNumber: cycleNumber, focus: "", pitchingDate: nil, proofOfContactDate: nil,
                  aRollBRollDate: nil, initialCutDate: nil, finalCutDate: nil)
    }
}
