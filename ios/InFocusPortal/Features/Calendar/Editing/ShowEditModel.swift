import Foundation
import Observation

/// One show's automatic edit on the Editing screen: loads `api/show-roles/edits` for the open
/// show, checks again every 10 seconds while an edit runs and every minute otherwise, and sends
/// each action (then reloads), like the Portal's `use-show-edit.ts`.
@MainActor @Observable
final class ShowEditModel {
    static let activePoll: Duration = .seconds(10)
    static let idlePoll: Duration = .seconds(60)

    let date: String
    private(set) var state: Loadable<ShowEditState> = .idle
    /// The action in flight (its name), so only one runs at a time.
    private(set) var busy: String?
    /// The last thing that went wrong, in the Portal's words.
    var error: String?
    /// The last thing that worked, for a short confirmation line.
    var notice: String?
    /// Recordings the producer changed; nil means the show's own recordings, preselected.
    var picked: [ShowEditSource]?

    private let api: ShowEditAPI

    init(date: String, api: ShowEditAPI) {
        self.date = date
        self.api = api
    }

    var selected: [ShowEditSource] {
        picked ?? state.value.map { ShowEditRules.defaultSelection($0.recordings, showDate: date) } ?? []
    }

    func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.state(date))
        } catch PortalError.forbidden {
            state = .failed("Automatic editing is for producers.")
        } catch {
            // A failed refresh keeps the last state on screen.
            if state.value == nil { state = .failed(CalendarDayEditor.message(for: error)) }
        }
    }

    /// Reloads until the screen goes away: faster while an edit or a sign-in is in flight.
    func follow() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: state.value?.isActive == true ? Self.activePoll : Self.idlePoll)
            guard !Task.isCancelled, busy == nil else { continue }
            await load()
        }
    }

    /// Sends one action, then reloads. Returns whether it worked.
    @discardableResult
    func send(_ action: ShowEditAction, success: String) async -> Bool {
        guard busy == nil else { return false }
        busy = action.name
        error = nil
        notice = nil
        defer { busy = nil }
        do {
            try await api.send(action)
            notice = success
            if case .start = action { picked = nil }
            await load()
            return true
        } catch {
            self.error = CalendarDayEditor.message(for: error)
            return false
        }
    }

    func start(note: String, publish: Date?) async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let slot = publish.flatMap { ShowEditRules.publishSlot($0, showDate: date) }
        await send(.start(date: date, sources: selected, note: trimmed.isEmpty ? nil : trimmed, publish: slot),
                   success: "Automatic editing queued.")
    }
}
