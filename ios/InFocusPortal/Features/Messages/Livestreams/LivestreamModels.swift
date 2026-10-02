import Foundation

/// `GET api/livestreams`: this semester's livestream schedule, as the web Livestreams page shows it.
struct LivestreamSchedule: Decodable, Sendable {
    struct Semester: Decodable, Sendable { let label: String }

    let semester: Semester
    let requiredHours: Double
    let canManage: Bool
    /// False for appointed livestream managers: they can't request sign-ups.
    let canSignup: Bool
    let currentUserId: String
    let mySignups: [LivestreamSignup]
    /// Everyone's pending requests (managers only; empty otherwise).
    let pendingSignups: [LivestreamSignup]
    let events: [LivestreamEvent]

    func event(_ id: String) -> LivestreamEvent? { events.first { $0.id == id } }
}

struct LivestreamPerson: Decodable, Hashable, Sendable {
    let id: String
    let name: String?

    var firstName: String { name?.split(separator: " ").first.map(String.init) ?? "Member" }
}

struct LivestreamEvent: Decodable, Hashable, Identifiable, Sendable {
    enum Status: String, Decodable, Sendable { case scheduled = "SCHEDULED", completed = "COMPLETED", cancelled = "CANCELLED" }
    enum Availability: String, Decodable, Sendable { case `public` = "PUBLIC", unlisted = "UNLISTED", unconfirmed = "UNCONFIRMED" }
    /// Crew space left: full, one spot, or two or more.
    enum CapacityTone: String, Decodable, Sendable { case full, one, open }

    struct MySignup: Decodable, Hashable, Sendable {
        let id: String
        let status: SignupStatus
    }

    let id: String
    let title: String
    let startsAt: Date
    let location: String
    let status: Status
    let availability: Availability
    let hours: Double?
    let capacity: Int
    let notes: String
    let manager: LivestreamPerson?
    let attendees: [LivestreamPerson]
    let attendeeCount: Int
    let openSlots: Int
    let capacityTone: CapacityTone
    let mySignup: MySignup?
    let pendingSignupCount: Int

    func isOnCrew(_ userId: String) -> Bool { attendees.contains { $0.id == userId } }
}

enum SignupStatus: String, Decodable, Sendable {
    case pending = "PENDING", approved = "APPROVED", denied = "DENIED"
}

struct LivestreamSignup: Decodable, Hashable, Identifiable, Sendable {
    struct EventRef: Decodable, Hashable, Sendable {
        let id: String
        let title: String
        let startsAt: Date
    }

    let id: String
    let eventId: String
    let status: SignupStatus
    let availableFullEvent: Bool
    let note: String?
    let createdAt: Date
    /// Managers' queue only.
    let user: LivestreamPerson?
    let event: EventRef?
}

struct SignupRequestBody: Encodable, Sendable {
    let eventId: String
    let availableFullEvent = true
    let note: String
}

/// What a person can do about one livestream (the web page's rules, `livestreams-client.tsx`).
enum SignupAction: Equatable {
    case onCrew
    case pending
    case request(again: Bool)
    case full
    case closed(String)
    case managerCannotSignUp

    static func `for`(_ event: LivestreamEvent, schedule: LivestreamSchedule) -> SignupAction {
        if event.isOnCrew(schedule.currentUserId) { return .onCrew }
        switch event.status {
        case .cancelled: return .closed("Cancelled")
        case .completed: return .closed("Completed")
        case .scheduled: break
        }
        if event.mySignup?.status == .pending { return .pending }
        guard schedule.canSignup else { return .managerCannotSignUp }
        if event.capacityTone == .full { return .full }
        return .request(again: event.mySignup?.status == .denied)
    }
}
