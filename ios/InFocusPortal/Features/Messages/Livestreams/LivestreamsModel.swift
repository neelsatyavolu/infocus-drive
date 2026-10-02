import Foundation
import Observation

/// The livestream schedule plus the sign-up and review actions on it.
@MainActor @Observable
final class LivestreamsModel {
    private(set) var state: Loadable<LivestreamSchedule> = .idle
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
