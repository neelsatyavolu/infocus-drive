import Foundation
import Observation

/// One visit to Story Ideas: the set on screen and which date was asked for (nil is the newest).
@MainActor @Observable
final class IdeasModel {
    private(set) var state: Loadable<IdeasPayload> = .idle
    private(set) var requested: String?

    init(date: String?) {
        requested = IdeasPage.validDate(date)
    }

    func load(api: CommunityAPI) async {
        if state.value == nil { state = .loading }
        let date = requested
        do {
            let payload = try await api.ideas(date)
            // A newer pick may have started while this one loaded.
            guard date == requested else { return }
            state = .loaded(payload)
        } catch is CancellationError {
            return
        } catch {
            guard date == requested else { return }
            state = .failed(Loadable<IdeasPayload>.message(for: error))
        }
    }

    /// Opens another set; the newest one is asked for without a date, as the web links it.
    func show(_ runDate: String?, api: CommunityAPI) async {
        let newest = state.value?.runDates.first
        let next = runDate == newest ? nil : IdeasPage.validDate(runDate)
        guard next != requested || state.value == nil else { return }
        requested = next
        state = .loading
        await load(api: api)
    }

    /// What to say when there's no set to show; nil when there is one.
    nonisolated static func emptyState(_ payload: IdeasPayload, requested: String?) -> (title: String, message: String, showLatest: Bool)? {
        guard let batch = payload.batch else {
            if requested != nil {
                let hasSets = !payload.runDates.isEmpty
                return ("No ideas for that date",
                        hasSets ? "Pick another date from Past ideas, or open the latest set." : "There are no sets to show yet.",
                        hasSets)
            }
            return ("No ideas yet",
                    "The first set arrives after the next daily check. After that, new ideas appear every \(IdeasFormat.intervalDays) days.",
                    false)
        }
        if batch.sections.isEmpty {
            return ("These ideas could not be shown", "Pick another date from Past ideas, or tell a producer.", false)
        }
        return nil
    }
}
