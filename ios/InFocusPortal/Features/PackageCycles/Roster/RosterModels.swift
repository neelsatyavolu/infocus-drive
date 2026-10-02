import Foundation

/// `GET api/package-progress?cycle=N` (producers): one cycle's roster.
struct RosterPayload: Decodable, Sendable {
    /// Executives, the adviser and the super admin edit the chart; associates only view it.
    let canEdit: Bool
    let canAssignProducer: Bool
    let activeCycleNumber: Int
    let cycles: [RosterCycle]
    let producers: [AssignablePerson]
    let executives: [AssignablePerson]
    /// Each member's groupmates last cycle (students may not repeat partners).
    let previousTeammatesByUser: [String: [String]]
    let rows: [RosterRow]
}

struct RosterCycle: Decodable, Hashable, Sendable, Identifiable {
    struct Dates: Decodable, Hashable, Sendable {
        let pitching: Date?
        let proofOfContact: Date?
        let aRollBRoll: Date?
        let initialCut: Date?
        let finalCut: Date?
    }

    let cycleNumber: Int
    let focus: String?
    let dates: Dates
    var id: Int { cycleNumber }
}

/// Someone a group can be assigned to: an associate producer or an executive.
struct AssignablePerson: Decodable, Hashable, Sendable, Identifiable {
    let userId: String
    let name: String?
    let email: String?
    var id: String { userId }
    var label: String { name?.trimmingCharacters(in: .whitespaces).rosterNonEmpty ?? email ?? "Producer" }
}

/// A class member from `GET api/platform/users` (producers), for the member picker.
struct RosterPerson: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let email: String?
    let name: String?
    let nickname: String?

    /// The on-screen name: nickname first (nicknames are what everyone sees).
    var displayName: String {
        nickname?.trimmingCharacters(in: .whitespaces).rosterNonEmpty
            ?? name?.trimmingCharacters(in: .whitespaces).rosterNonEmpty
            ?? email ?? "Member"
    }

    /// The first name stored in the group's legacy members text (`@[First](id)`), as the web picks it.
    var mentionFirstName: String {
        let source = name?.trimmingCharacters(in: .whitespaces).rosterNonEmpty
            ?? email?.split(separator: "@").first.map(String.init)?.trimmingCharacters(in: .whitespaces).rosterNonEmpty
            ?? "User"
        return source.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "User"
    }
}

struct RosterMember: Hashable, Sendable, Identifiable {
    let userId: String
    let name: String
    var id: String { userId }
}

/// One group, kept as the raw object the Portal sent (see `JSONValue`).
struct RosterRow: Decodable, Hashable, Sendable, Identifiable {
    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) { self.raw = raw }

    init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    /// Saved rows have an id; a row only exists unsaved inside a save.
    var id: String { raw["id"]?.string ?? "" }
    var topic: String { raw["groupTopic"]?.string ?? "" }
    var interviews: String { raw["possibleInterviews"]?.string ?? "" }
    var ideas: String { raw["possibleIdeas"]?.string ?? "" }
    var notes: String { raw["notes"]?.string ?? "" }
    var memberUserIds: [String] { raw["memberUserIds"]?.array?.compactMap(\.string) ?? [] }
    var assignedProducerUserId: String? { raw["assignedProducerUserId"]?.string }
    var assignedExecutiveUserId: String? { raw["assignedExecutiveProducerUserId"]?.string }

    var members: [RosterMember] {
        (raw["members"]?.array ?? []).compactMap { value in
            guard let object = value.object, let userId = object["userId"]?.string else { return nil }
            let name = object["name"]?.string?.rosterNonEmpty ?? object["email"]?.string ?? "Member"
            return RosterMember(userId: userId, name: name)
        }
    }

    func flag(_ key: String) -> Bool { raw[key]?.bool ?? false }

    var queuedForAir: Bool { flag("queuedForAir") }
    var isPackageOfCycle: Bool { raw["packageOfCycleAt"]?.string != nil }
    var hasExtension: Bool { (raw["extensionDays"]?.number ?? 0) > 0 || flag("extension") }
    var extensionDays: Double { raw["extensionDays"]?.number ?? 0 }

    /// Name of the person in an `assignedProducer` / `assignedExecutiveProducer` object.
    func assignedName(_ key: String) -> String? {
        guard let object = raw[key]?.object else { return nil }
        return object["name"]?.string?.rosterNonEmpty ?? object["email"]?.string
    }
}

/// `POST api/package-progress`: every row of the cycle, in order.
struct RosterSave: Encodable {
    let cycleNumber: Int
    let rows: [[String: JSONValue]]
}

extension String {
    var rosterNonEmpty: String? { isEmpty ? nil : self }
}
