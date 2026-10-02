import Foundation

/// `GET api/package-progress[?cycle=]` (producers): every package of a cycle.
struct GroupsPayload: Decodable, Sendable {
    let activeCycleNumber: Int
    let cycles: [CycleInfo]
    let rows: [GroupRow]
}

struct CycleInfo: Decodable, Sendable, Hashable, Identifiable {
    struct Dates: Decodable, Sendable, Hashable {
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

struct ProofView: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let slot: Int
    let fileName: String
    let imageUrl: String
}

/// One package on the Groups tiles (the fields the tiles read).
struct GroupRow: Decodable, Sendable, Hashable, Identifiable {
    struct ReviewReadyAt: Decodable, Sendable, Hashable {
        let brainstorming: Date?
        let aRoll: Date?
        let initialCut: Date?

        enum CodingKeys: String, CodingKey {
            case brainstorming
            case aRoll = "a-roll"
            case initialCut = "initial-cut"
        }
    }

    let id: String
    let groupTopic: String
    let groupType: String?
    let assignedProducerUserId: String?
    let assignedProducer: PackagePerson?
    let assignedExecutiveProducerUserId: String?
    let assignedExecutiveProducer: PackagePerson?
    let members: [PackagePerson]
    let reviewReadyAt: ReviewReadyAt?
    let pitching: Bool
    let proofOfContact: Bool
    let aRollBRoll: Bool
    let aRollHasMedia: Bool
    let aRollNeedsChanges: Bool?
    let initialCutMediaItemId: String?
    let initialCutVersionNumber: Int?
    let initialCutNeedsRevisions: Bool
    let awaitingRevisedInitialCut: Bool
    let approvalStage: String
    let remainingExecutiveSignoffs: Int?
    let finalCutMediaItemId: String?
    let queuedForAir: Bool
    let finalCutGraded: Bool?
    let brainstormDocUrl: String?
    let proofs: [ProofView]
    let extensionDays: Double?

    var topic: String { groupTopic.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled package" : groupTopic }
    var memberNames: String { members.map(\.displayName).joined(separator: ", ") }

    /// Assigned to this producer (as the associate or the executive), matched by email.
    func isAssigned(toEmail email: String) -> Bool {
        let me = email.lowercased()
        return assignedProducer?.email?.lowercased() == me || assignedExecutiveProducer?.email?.lowercased() == me
    }
}

/// `GET api/brainstorming`: the student's brainstorm (doc link + three proofs of contact).
struct BrainstormPayload: Decodable, Sendable {
    let activeCycleNumber: Int
    let packages: [BrainstormPackage]
}

struct BrainstormPackage: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let cycleNumber: Int
    let groupTopic: String
    let brainstormDocUrl: String?
    let proofOfContact: Bool
    let assignedProducer: PackagePerson?
    let members: [PackagePerson]
    let proofs: [ProofView]

    static let proofSlots = [1, 2, 3]

    func proof(in slot: Int) -> ProofView? { proofs.first { $0.slot == slot } }
}

/// The Portal's rule for a Google Docs/Drive link (`isGoogleDocUrl`).
enum GoogleDocLink {
    static func isValid(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "docs.google.com" || host == "drive.google.com"
    }
}
