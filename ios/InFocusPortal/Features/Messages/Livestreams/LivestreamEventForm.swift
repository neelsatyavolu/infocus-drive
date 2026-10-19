import Foundation

/// The web's event editor (`livestreams-form.ts`): the fields, their checks, and the body for
/// `POST api/livestreams/events` and `PATCH api/livestreams/events/<id>`.
struct LivestreamEventForm: Equatable {
    var title = ""
    var startsAt: Date
    /// Only the time of day counts; the day is the start's (Pacific).
    var arrivesAt: Date
    var location = ""
    var status: LivestreamEvent.Status = .scheduled
    var availability: LivestreamEvent.Availability = .unconfirmed
    var hours = ""
    var capacity = "4"
    var notes = ""
    var manager: LivestreamPerson?
    var crew: [LivestreamPerson] = []
    /// Per-crew credit hours as typed (blank: the event's hours).
    var credits: [String: String] = [:]

    static let hoursError = "Hours must be from 0 to 24, in steps of 0.25."
    static let capacityError = "Capacity must be a whole number from 1 to 50."
    static let creditError = "Credit hours must be from 0 to 24, in steps of 0.25."
    static let notesLimit = 1000

    /// A new event: now, Unconfirmed, the schedule's default capacity (the web's defaults).
    init(now: Date = Date(), capacity: Int = 4) {
        startsAt = now
        arrivesAt = now
        self.capacity = String(capacity)
    }

    /// Every field from the event; `complete` presets Completed (the web's "Complete…").
    init(event: LivestreamEvent, complete: Bool = false) {
        title = event.title
        startsAt = event.startsAt
        arrivesAt = event.arrivesAt ?? event.startsAt
        location = event.location
        status = complete ? .completed : event.status
        availability = event.availability
        hours = event.hours.map(LivestreamEventForm.format) ?? ""
        capacity = String(event.capacity)
        notes = event.notes
        manager = event.manager
        crew = event.attendees
        credits = Dictionary(uniqueKeysWithValues: event.attendees.map { ($0.id, $0.creditHours.map(LivestreamEventForm.format) ?? "") })
    }

    // MARK: Checks

    enum Field: Hashable { case title, hours, capacity, completedHours }

    struct Errors: Equatable {
        var fields: [Field: String] = [:]
        /// Crew whose own credit hours are out of range.
        var credits: Set<String> = []
        var isEmpty: Bool { fields.isEmpty && credits.isEmpty }
    }

    func validate() -> Errors {
        var errors = Errors()
        if title.trimmingCharacters(in: .whitespaces).isEmpty { errors.fields[.title] = "Title is required." }
        if !Self.validHours(hours) { errors.fields[.hours] = Self.hoursError }
        if !Self.validCapacity(capacity) { errors.fields[.capacity] = Self.capacityError }
        // The API refuses Completed without hours; say so beside the field instead.
        if status == .completed, hours.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.fields[.completedHours] = "Hours are required when marking an event completed."
        }
        errors.credits = Set(crew.map(\.id).filter { !Self.validHours(credits[$0] ?? "") })
        return errors
    }

    /// Blank, or 0–24 in quarter hours.
    static func validHours(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        guard let hours = Double(trimmed), hours >= 0, hours <= 24 else { return false }
        return abs(hours * 4 - (hours * 4).rounded()) < 1e-6
    }

    /// Blank (the default), or a whole number 1–50.
    static func validCapacity(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        guard let capacity = Int(trimmed) else { return false }
        return (1...50).contains(capacity)
    }

    /// 2.5, 3, 0.25 (no float noise).
    static func format(_ hours: Double) -> String {
        let rounded = (hours * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    // MARK: Crew

    mutating func add(_ person: LivestreamPerson) {
        guard !crew.contains(where: { $0.id == person.id }) else { return }
        crew.append(person)
    }

    mutating func remove(_ personId: String) {
        crew.removeAll { $0.id == personId }
        credits[personId] = nil
    }

    // MARK: Body

    /// The arrival on the start's Pacific day, at the arrival's Pacific time of day.
    var arrival: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = FeatureDates.timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: startsAt)
        let time = calendar.dateComponents([.hour, .minute], from: arrivesAt)
        var parts = DateComponents()
        parts.year = day.year
        parts.month = day.month
        parts.day = day.day
        parts.hour = time.hour
        parts.minute = time.minute
        return calendar.date(from: parts) ?? arrivesAt
    }

    var body: LivestreamEventBody {
        func number(_ text: String) -> Double? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : Double(trimmed)
        }
        let ids = crew.map(\.id)
        return LivestreamEventBody(
            title: title.trimmingCharacters(in: .whitespaces),
            startsAt: Self.wholeMinute(startsAt),
            arrivesAt: Self.wholeMinute(arrival),
            location: location.trimmingCharacters(in: .whitespaces),
            status: status,
            availability: availability,
            hours: number(hours),
            capacity: Int(capacity.trimmingCharacters(in: .whitespaces)) ?? 4,
            notes: String(notes.prefix(Self.notesLimit)),
            managerUserId: manager?.id,
            attendeeCredits: ids.map { .init(userId: $0, creditHours: number(credits[$0] ?? "")) },
            attendeeUserIds: ids)
    }

    /// The web's datetime-local field has no seconds.
    static func wholeMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }
}

/// The JSON for creating or saving an event. `hours`, `managerUserId` and each `creditHours`
/// are sent as `null` when blank (clearing them), exactly like the web.
struct LivestreamEventBody: Encodable, Sendable, Equatable {
    struct Credit: Encodable, Sendable, Equatable {
        let userId: String
        let creditHours: Double?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(userId, forKey: .userId)
            try container.encode(creditHours, forKey: .creditHours)
        }

        private enum CodingKeys: String, CodingKey { case userId, creditHours }
    }

    let title: String
    let startsAt: Date
    let arrivesAt: Date
    let location: String
    let status: LivestreamEvent.Status
    let availability: LivestreamEvent.Availability
    let hours: Double?
    let capacity: Int
    let notes: String
    let managerUserId: String?
    let attendeeCredits: [Credit]
    let attendeeUserIds: [String]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(startsAt, forKey: .startsAt)
        try container.encode(arrivesAt, forKey: .arrivesAt)
        try container.encode(location, forKey: .location)
        try container.encode(status, forKey: .status)
        try container.encode(availability, forKey: .availability)
        try container.encode(hours, forKey: .hours)
        try container.encode(capacity, forKey: .capacity)
        try container.encode(notes, forKey: .notes)
        try container.encode(managerUserId, forKey: .managerUserId)
        try container.encode(attendeeCredits, forKey: .attendeeCredits)
        try container.encode(attendeeUserIds, forKey: .attendeeUserIds)
    }

    private enum CodingKeys: String, CodingKey {
        case title, startsAt, arrivesAt, location, status, availability, hours, capacity, notes, managerUserId,
             attendeeCredits, attendeeUserIds
    }
}
