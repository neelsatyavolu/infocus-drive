import Foundation

/// Equipment checkout (`src/server/equipment*.ts`). Borrowers are matched by email; the
/// checkout kiosk (a station unlocked with a separate Google sign-in) stays on the web.

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
            status == .pending && !items.isEmpty
                && items.allSatisfy { !$0.item.checkedOut && $0.item.onHoldForStudentId == nil && $0.item.archivedAt == nil }
        }

        /// Items still held for this request (checked out ones no longer are).
        var remainingHolds: Int { items.filter { $0.item.holdRequestId == id }.count }

        /// Deny a pending request, or an approved one while none of its items is out and some
        /// are still held for it (denying releases those holds). `src/lib/equipment-requests.ts`.
        var canDeny: Bool {
            switch status {
            case .pending: true
            case .denied: false
            case .approved: !items.contains { $0.item.checkedOut } && remainingHolds > 0
            }
        }

        /// Approved and every hold picked up.
        var fulfilled: Bool { status == .approved && remainingHolds == 0 }

        var word: String { fulfilled ? "Fulfilled" : status.word }
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
    var holdRequestId: String? = nil
}

/// `GET api/equipment/manage/out` (every item out or on hold) and `GET api/equipment/manage/items`
/// (the whole inventory, not archived).
struct ManagedOut: Decodable, Sendable {
    struct Item: Decodable, Hashable, Identifiable, Sendable {
        enum State: Sendable { case `in`, out, held }

        let id: String
        let name: String
        let barcode: String
        let checkedOut: Bool
        let checkedOutAt: Date?
        let checkedOutBy: GearBorrower?
        let onHoldForStudent: GearBorrower?
        let tookSdCard: Bool?
        var onHoldForStudentId: String? = nil

        var state: State {
            if checkedOut { return .out }
            if onHoldForStudentId != nil || onHoldForStudent != nil { return .held }
            return .in
        }

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

// MARK: Inventory

/// `POST api/equipment/manage/items`.
struct NewGearBody: Encodable, Sendable {
    let name: String
    let barcode: String
}

/// `PATCH api/equipment/manage/items`: rename/recode, or `archived: true`.
struct GearPatchBody: Encodable, Sendable {
    let id: String
    var name: String?
    var barcode: String?
    var archived: Bool?
}

/// The Out tab's filters (the web's All / Out / Held / Overdue chips).
enum OutFilter: String, CaseIterable, Hashable, Sendable {
    case all, out, held, overdue

    var title: String { rawValue.capitalized }

    func includes(_ item: ManagedOut.Item, now: Date = Date()) -> Bool {
        switch self {
        case .all: true
        case .out: item.state == .out
        case .held: item.state == .held
        case .overdue: item.isOverdue(now: now)
        }
    }
}
