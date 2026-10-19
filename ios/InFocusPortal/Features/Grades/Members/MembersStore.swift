import Foundation
import Observation

/// Members and their notes, with the web page's autosave: a note saves 0.7 s after typing
/// stops and when its screen closes. One save per note is out at a time; text typed meanwhile
/// goes next, so the newest text always wins.
@MainActor @Observable
final class MembersStore {
    private(set) var state: Loadable<MembersPayload> = .idle
    private(set) var drafts: [String: String] = [:]
    private(set) var saved: [String: String] = [:]
    private(set) var saving: Set<String> = []
    private(set) var justSaved: Set<String> = []
    private(set) var failures: [String: String] = [:]

    private var touched: Set<String> = []
    private var timers: [String: Task<Void, Never>] = [:]
    private var resave: Set<String> = []
    private let service: MembersService
    private let delay: Duration

    init(service: MembersService, delay: Duration = .milliseconds(700)) {
        self.service = service
        self.delay = delay
    }

    var payload: MembersPayload? { state.value }

    /// General first, then every cycle.
    var tabs: [Int] { [MembersLogic.generalCycle] + (payload?.cycles.map(\.cycleNumber) ?? []) }

    func load() async {
        if state.value == nil { state = .loading }
        do {
            let payload = try await service.members()
            // A fresh copy replaces every note not edited on this visit.
            let server = MembersLogic.notes(from: payload.members)
            var nextDrafts = server, nextSaved = server
            for key in touched {
                if let draft = drafts[key] { nextDrafts[key] = draft }
                if let kept = saved[key] { nextSaved[key] = kept }
            }
            drafts = nextDrafts
            saved = nextSaved
            state = .loaded(payload)
        } catch PortalError.forbidden {
            state = .failed("Members isn't available for this account.")
        } catch {
            if state.value == nil { state = .failed(Loadable<MembersPayload>.message(for: error)) }
        }
    }

    func note(_ userId: String, _ cycle: Int) -> String { drafts[MembersLogic.key(userId, cycle)] ?? "" }

    func noteState(_ userId: String, _ cycle: Int) -> MemberNoteState {
        let key = MembersLogic.key(userId, cycle)
        if saving.contains(key) { return .saving }
        if let message = failures[key] { return .failed(message) }
        if (drafts[key] ?? "") != (saved[key] ?? "") { return .dirty }
        return justSaved.contains(key) ? .saved : .idle
    }

    func setNote(_ userId: String, _ cycle: Int, _ text: String) {
        let key = MembersLogic.key(userId, cycle)
        touched.insert(key)
        drafts[key] = String(text.prefix(MembersLogic.noteMax))
        timers[key]?.cancel()
        timers[key] = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.persist(key)
        }
    }

    /// Sends every note still waiting on its timer, and every note whose save failed.
    func flushAll() {
        let keys = Set(timers.keys).union(failures.keys)
        timers.values.forEach { $0.cancel() }
        timers = [:]
        for key in keys { Task { await persist(key) } }
    }

    func persist(_ key: String) async {
        timers[key] = nil
        guard let parsed = MembersLogic.parseKey(key) else { return }
        if saving.contains(key) {
            resave.insert(key)
            return
        }
        let text = String((drafts[key] ?? "").prefix(MembersLogic.noteMax))
        guard text != (saved[key] ?? "") else {
            failures[key] = nil
            return
        }
        saving.insert(key)
        do {
            let result = try await service.save(MemberNoteSave(userId: parsed.userId, cycleNumber: parsed.cycle, notes: text))
            saved[key] = result.notes
            failures[key] = nil
            justSaved.insert(key)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.justSaved.remove(key)
            }
        } catch {
            failures[key] = Loadable<MembersPayload>.message(for: error)
        }
        saving.remove(key)
        if resave.remove(key) != nil { await persist(key) }
    }
}
