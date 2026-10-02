import Foundation

/// Equipment checkout (`src/server/equipment*.ts`). Borrowers are matched by email; the
/// checkout kiosk and Inventory stay on the web.

struct GearItem: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let barcode: String
}

/// `GET api/equipment/me`.
struct EquipmentAccess: Decodable, Sendable {
    let signedIn: Bool
    let canManage: Bool
}

/// `GET api/equipment/mine`: what this person has out, has on hold, and asked for.
struct MyEquipment: Decodable, Sendable {
    struct OutItem: Decodable, Hashable, Identifiable, Sendable {
        let id: String
        let name: String
        let barcode: String
        let checkedOutAt: Date?
        let dueAt: Date?
        let overdue: Bool
    }

    struct Request: Decodable, Hashable, Identifiable, Sendable {
        let id: String
        let status: RequestStatus
        let fulfilled: Bool
        let createdAt: Date
        let items: [GearItem]

        /// The web's four words: Pending, Approved, Denied, Fulfilled.
        var word: String { fulfilled ? "Fulfilled" : status.word }
    }

    let overdueAfterHours: Int
    let out: [OutItem]
    let held: [GearItem]
    let requests: [Request]

    var isEmpty: Bool { out.isEmpty && held.isEmpty && requests.isEmpty }
}

enum RequestStatus: String, Decodable, Sendable {
    case pending = "PENDING", approved = "APPROVED", denied = "DENIED"

    var word: String {
        switch self {
        case .pending: "Pending"
        case .approved: "Approved"
        case .denied: "Denied"
        }
    }
}

/// `GET api/equipment/public/items`: items in, not held, not archived.
struct AvailableGear: Decodable, Sendable {
    let items: [GearItem]
}

/// `POST api/equipment/public/requests`.
struct GearRequestBody: Encodable, Sendable {
    let studentName: String
    let studentId: String
    let email: String
    let barcodes: [String]
}

// MARK: Managers

struct GearBorrower: Decodable, Hashable, Sendable {
    let name: String?
    let studentId: String
    let email: String?

    var label: String { name?.isEmpty == false ? name! : studentId }
}

/// `GET api/equipment/manage/requests`.
struct ManagedRequests: Decodable, Sendable {
    struct Request: Decodable, Hashable, Identifiable, Sendable {
        struct Line: Decodable, Hashable, Sendable { let item: ManagedItem }

        let id: String
        let status: RequestStatus
        let email: String
        let createdAt: Date
        let student: GearBorrower
        let items: [Line]

        /// Approve holds the items: only while every one is in, unheld and not archived.
        var canApprove: Bool {
            status == .pending && items.allSatisfy { !$0.item.checkedOut && $0.item.onHoldForStudentId == nil && $0.item.archivedAt == nil }
        }

        /// Deny a pending request, or an approved one while none of its items is out (releases holds).
        var canDeny: Bool {
            status == .pending || (status == .approved && items.allSatisfy { !$0.item.checkedOut })
        }
    }

    let requests: [Request]
}

struct ManagedItem: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let barcode: String
    let checkedOut: Bool
    let checkedOutAt: Date?
    let onHoldForStudentId: String?
    let archivedAt: Date?
}

/// `GET api/equipment/manage/out`: every item out or on hold.
struct ManagedOut: Decodable, Sendable {
    struct Item: Decodable, Hashable, Identifiable, Sendable {
        let id: String
        let name: String
        let barcode: String
        let checkedOut: Bool
        let checkedOutAt: Date?
        let checkedOutBy: GearBorrower?
        let onHoldForStudent: GearBorrower?
        let tookSdCard: Bool?

        func isOverdue(now: Date = Date(), afterHours: Int = 72) -> Bool {
            guard checkedOut, let checkedOutAt else { return false }
            return now.timeIntervalSince(checkedOutAt) >= Double(afterHours) * 3600
        }
    }

    let items: [Item]
}

struct ManageDecision: Encodable, Sendable {
    let id: String
    let action: String
}

struct OutAction: Encodable, Sendable {
    let action: String
    let itemId: String
}
