import Foundation

/// `GET api/extensions/requests`: students get their groups' requests,
/// producers the whole queue (`app/api/extensions/requests/route.ts`).
struct ExtensionRequestsPayload: Decodable, Hashable, Sendable {
    /// This person can approve or deny at least one request.
    let canDecide: Bool
    /// Execs can grant extensions outright (done on the web).
    let canGrant: Bool
    let currentUserId: String
    let approvalsRequired: Int
    let requests: [ExtensionRequest]
}

struct ExtensionRequest: Decodable, Hashable, Sendable, Identifiable {
    enum Status: String, Decodable, Sendable {
        case pending = "PENDING", approved = "APPROVED", denied = "DENIED"
    }

    struct Person: Decodable, Hashable, Sendable {
        let id: String
        let name: String?
        let email: String?
    }

    struct Member: Decodable, Hashable, Sendable {
        let userId: String
        let name: String?
        let email: String?
    }

    struct Consent: Decodable, Hashable, Sendable {
        let userId: String
        let agreed: Bool
        let name: String?
    }

    struct Approval: Decodable, Hashable, Sendable {
        let userId: String
        let approved: Bool
        let reason: String
        let name: String?
    }

    let id: String
    let cycleNumber: Int
    let requestedDays: Double
    let grantedDays: Double?
    /// Empty means the whole group.
    let grantedUserIds: [String]
    /// An exec granted it directly: no group agreement needed.
    let producerGranted: Bool
    let reason: String
    let status: Status
    let createdAt: Date
    let decidedAt: Date?
    let groupTopic: String
    let student: Person
    let groupMembers: [Member]
    let memberConsents: [Consent]
    let memberConsentComplete: Bool
    /// This person may approve or deny it.
    let canDecide: Bool
    let approvalsRequired: Int
    let approvals: [Approval]
}
