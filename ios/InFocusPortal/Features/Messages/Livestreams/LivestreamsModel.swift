import Foundation
import Observation

/// The livestream schedule plus the sign-up and review actions on it.
@MainActor @Observable
final class LivestreamsModel {
    private(set) var state: Loadable<LivestreamSchedule> = .idle
    private(set) var completion: Loadable<LivestreamCompletion> = .idle
    private(set) var members: Loadable<[PortalMember]> = .idle
    private(set) var busy: String?
    var actionError: String?
    var notice: String?

    private let service: LivestreamService

    init(service: LivestreamService) {
        self.service = service
    }

    func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await service.schedule())
        } catch {
            if state.value == nil { state = .failed(Loadable<LivestreamSchedule>.message(for: error)) }
        }
    }

    func requestSignup(_ event: LivestreamEvent, note: String) async -> Bool {
        await run(event.id, success: "Requested. A livestream manager will review it.") {
            try await self.service.requestSignup(event.id, note.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func review(_ signup: LivestreamSignup, approve: Bool) async {
        _ = await run(signup.id, success: approve ? "Approved. They're on the crew." : "Denied.") {
            try await self.service.review(signup.id, approve)
        }
    }

    func loadCompletion() async {
        if completion.value == nil { completion = .loading }
        do {
            completion = .loaded(try await service.completion())
        } catch {
            if completion.value == nil { completion = .failed(Loadable<LivestreamCompletion>.message(for: error)) }
        }
    }

    func loadMembers() async {
        guard members.value == nil else { return }
        members = .loading
        do {
            members = .loaded(try await service.members())
        } catch {
            members = .failed(Loadable<[PortalMember]>.message(for: error))
        }
    }

    /// Creates (`event` nil) or saves an event; true when saved.
    func save(_ form: LivestreamEventForm, event: LivestreamEvent?) async -> Bool {
        let body = form.body
        let saved = await run(event?.id ?? "new", success: event == nil ? "Added \(body.title)." : "Saved.") {
            try await self.service.saveEvent(event?.id, body)
        }
        if saved, completion.value != nil { await loadCompletion() }
        return saved
    }

    func delete(_ event: LivestreamEvent) async -> Bool {
        await run(event.id, success: "Deleted \(event.title).") { try await self.service.deleteEvent(event.id) }
    }

    func addManager(_ member: PortalMember) async {
        _ = await run(member.id, success: "\(member.label) can now manage livestreams.") {
            try await self.service.addManager(member.id)
        }
    }

    func removeManager(_ person: LivestreamPerson) async {
        _ = await run(person.id, success: "Removed \(person.label).") { try await self.service.removeManager(person.id) }
    }

    private func run(_ key: String, success: String, _ action: @escaping () async throws -> Void) async -> Bool {
        busy = key
        defer { busy = nil }
        do {
            try await action()
            notice = success
            await load()
            return true
        } catch {
            actionError = Loadable<LivestreamSchedule>.message(for: error)
            return false
        }
    }

    /// Today and later first (soonest first), then earlier ones (most recent first), like the web schedule.
    nonisolated static func split(_ events: [LivestreamEvent], now: Date = Date()) -> (upcoming: [LivestreamEvent], earlier: [LivestreamEvent]) {
        let upcoming = events.filter { !FeatureDates.isBeforeToday($0.startsAt, now: now) }.sorted { $0.startsAt < $1.startsAt }
        let earlier = events.filter { FeatureDates.isBeforeToday($0.startsAt, now: now) }.sorted { $0.startsAt > $1.startsAt }
        return (upcoming, earlier)
    }
}
