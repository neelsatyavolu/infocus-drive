import Foundation

/// The roster's filters, as the web toolbar has them (`ROSTER_FILTERS` in roster-model.ts).
enum RosterFilter: String, CaseIterable, Identifiable {
    case all, noProducer, noMembers, repeated, mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .noProducer: "No producer"
        case .noMembers: "No members"
        case .repeated: "Same group last cycle"
        case .mine: "Assigned to me"
        }
    }

    /// `viewerId`: the signed-in producer's user id, when they're on the assignable list.
    func matches(_ row: RosterRow, previous: [String: [String]], viewerId: String?) -> Bool {
        switch self {
        case .all:
            return true
        case .noProducer:
            return Self.nonEmpty(row.assignedProducerUserId) == nil && Self.nonEmpty(row.assignedExecutiveUserId) == nil
        case .noMembers:
            return row.memberUserIds.isEmpty
                && (row.raw["groupMembers"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .repeated:
            return !RosterLogic.repeatedPairs(row.memberUserIds, previous: previous).isEmpty
        case .mine:
            // The assigned EP wins over the assigned AP (`selectedAssignedProducerId`).
            guard let viewerId else { return false }
            return (Self.nonEmpty(row.assignedExecutiveUserId) ?? Self.nonEmpty(row.assignedProducerUserId)) == viewerId
        }
    }

    /// The viewer's user id, found by email among the people a group can be assigned to.
    static func viewerId(email: String?, in roster: RosterPayload) -> String? {
        guard let email = email?.lowercased(), !email.isEmpty else { return nil }
        return (roster.executives + roster.producers).first { $0.email?.lowercased() == email }?.userId
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
