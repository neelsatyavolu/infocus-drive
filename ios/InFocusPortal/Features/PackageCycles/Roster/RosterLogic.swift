import Foundation

/// The roster rules the web chart follows (Portal `src/lib/package-producer-assignment.ts`,
/// `consecutive-groupmates.ts`, `members-editor.tsx`), kept pure so they're testable.
enum RosterLogic {
    /// One assigned producer per group: picking an executive clears the associate and the
    /// other way round; nil unassigns both.
    static func assign(_ row: inout [String: JSONValue], to userId: String?, executiveIds: Set<String>) {
        let isExecutive = userId.map(executiveIds.contains) ?? false
        row["assignedProducerUserId"] = isExecutive ? .null : .optional(userId)
        row["assignedExecutiveProducerUserId"] = isExecutive ? .optional(userId) : .null
        row["assignedProducer"] = .null
        row["assignedExecutiveProducer"] = .null
    }

    /// The legacy members text the Portal still matches cut status against: `@[First](id), …`.
    static func groupMembersText(_ ids: [String], people: [String: RosterPerson]) -> String {
        ids.compactMap { id in people[id].map { "@[\($0.mentionFirstName)](\(id))" } }
            .joined(separator: ", ")
    }

    /// Replaces the members of a row (deduplicated, order kept) and its members text.
    static func setMembers(_ row: inout [String: JSONValue], ids: [String], people: [String: RosterPerson]) {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        row["memberUserIds"] = .array(unique.map(JSONValue.string))
        row["groupMembers"] = .string(groupMembersText(unique, people: people))
        row["members"] = .array(unique.compactMap { id in
            people[id].map { .object(["userId": .string(id), "name": .string($0.displayName), "email": .optional($0.email)]) }
        })
    }

    /// Current members who shared a group with another current member last cycle.
    static func repeatedPairs(_ memberIds: [String], previous: [String: [String]]) -> [(userId: String, with: [String])] {
        let current = Set(memberIds)
        return memberIds.compactMap { id in
            let with = Array(Set(previous[id] ?? [])).filter { $0 != id && current.contains($0) }.sorted()
            return with.isEmpty ? nil : (id, with)
        }
    }

    /// For the picker: members of this group that `userId` was grouped with last cycle.
    static func lastCycleGroupmates(of userId: String, among memberIds: [String], previous: [String: [String]]) -> [String] {
        let before = Set(previous[userId] ?? [])
        return memberIds.filter { $0 != userId && before.contains($0) }
    }

    /// A blank group, as the web's Add Group makes it.
    static func newRow() -> [String: JSONValue] {
        var row: [String: JSONValue] = [
            "groupMembers": .string(""), "groupTopic": .string(""), "groupType": .string(""), "category": .null,
            "assignedProducerUserId": .null, "assignedExecutiveProducerUserId": .null, "memberUserIds": .array([]),
            "initialCutMediaItemId": .null, "finalCutMediaItemId": .null, "stageNotes": .null,
            "possibleInterviews": .string(""), "possibleIdeas": .string(""), "notes": .string(""),
        ]
        for flag in ["revisedInitialCut", "pitching", "proofOfContact", "aRollBRoll", "initialCut",
                     "initialCutManual", "finalCut", "finalCutManual", "extension"] {
            row[flag] = .bool(false)
        }
        return row
    }

    struct Stats: Equatable {
        let total: Int
        let withMembers: Int
        let withAssigned: Int
    }

    static func stats(_ rows: [RosterRow]) -> Stats {
        Stats(total: rows.count,
              withMembers: rows.filter { !$0.memberUserIds.isEmpty || !($0.raw["groupMembers"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count,
              withAssigned: rows.filter { $0.assignedProducerUserId != nil || $0.assignedExecutiveUserId != nil }.count)
    }

    /// "Name · EP", "Name · AP", or nil when unassigned.
    static func assignedLabel(_ row: RosterRow, producers: [AssignablePerson], executives: [AssignablePerson]) -> String? {
        if let id = row.assignedExecutiveUserId {
            let name = row.assignedName("assignedExecutiveProducer") ?? executives.first { $0.userId == id }?.label ?? "Executive"
            return "\(name) · EP"
        }
        if let id = row.assignedProducerUserId {
            let name = row.assignedName("assignedProducer") ?? producers.first { $0.userId == id }?.label ?? "Associate"
            return "\(name) · AP"
        }
        return nil
    }

    /// Everyone a group can be assigned to, executives first, each once.
    static func assignable(producers: [AssignablePerson], executives: [AssignablePerson]) -> [(person: AssignablePerson, isExecutive: Bool)] {
        var seen = Set<String>()
        let executiveIds = Set(executives.map(\.userId))
        return (executives + producers).compactMap { person in
            seen.insert(person.userId).inserted ? (person, executiveIds.contains(person.userId)) : nil
        }
    }
}

/// The five package stages, in order (no skipping).
enum RosterStage: Int, CaseIterable, Identifiable, Sendable {
    case pitching, proofOfContact, aRollBRoll, initialCut, finalCut

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .pitching: "Package Pitching"
        case .proofOfContact: "Brainstorming & Proof of Contact"
        case .aRollBRoll: "A-roll/B-roll"
        case .initialCut: "Initial Cut"
        case .finalCut: "Final Cut"
        }
    }

    var shortTitle: String {
        switch self {
        case .pitching: "Pitch"
        case .proofOfContact: "Contact"
        case .aRollBRoll: "A/B-roll"
        case .initialCut: "Initial"
        case .finalCut: "Final"
        }
    }

    /// The roster row's completion flag for this stage.
    var rowKey: String {
        switch self {
        case .pitching: "pitching"
        case .proofOfContact: "proofOfContact"
        case .aRollBRoll: "aRollBRoll"
        case .initialCut: "initialCut"
        case .finalCut: "finalCut"
        }
    }

    static func done(_ row: RosterRow) -> [RosterStage] {
        allCases.filter { row.flag($0.rowKey) }
    }

    /// The first stage not done yet; nil once Final Cut is done.
    static func current(_ row: RosterRow) -> RosterStage? {
        allCases.first { !row.flag($0.rowKey) }
    }
}
