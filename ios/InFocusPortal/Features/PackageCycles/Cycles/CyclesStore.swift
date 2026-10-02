import Foundation
import Observation

/// The Package Cycles page: stage dates for each cycle and Package of the Cycle winners.
@MainActor @Observable
final class CyclesStore {
    struct Page: Sendable {
        let cycles: CyclesPayload
        /// nil when the winners couldn't load (the dates still show).
        let winners: WinnersPayload?
    }

    private(set) var state: Loadable<Page> = .idle
    private(set) var saving = false
    var errorMessage: String?
    var notice: String?

    let service: PackageCyclesService

    init(service: PackageCyclesService) {
        self.service = service
    }

    func load() async {
        if state.value == nil { state = .loading }
        do {
            async let cycles = service.cycles()
            async let winners = try? service.winners()
            state = .loaded(Page(cycles: try await cycles, winners: await winners))
        } catch {
            if state.value == nil { state = .failed(Loadable<Page>.message(for: error)) }
            else { errorMessage = Loadable<Page>.message(for: error) }
        }
    }

    func save(_ cycle: CycleDates) async -> Bool {
        await perform(success: "Cycle \(cycle.cycleNumber) saved.") { [service] in try await service.saveCycle(cycle) }
    }

    func setCount(_ count: Int) async -> Bool {
        await perform(success: "This semester now has \(count) package cycle\(count == 1 ? "" : "s").") { [service] in
            try await service.setCyclesPerSemester(count)
        }
    }

    private func perform(success: String, _ action: @escaping () async throws -> Void) async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        do {
            try await action()
            await load()
            notice = success
            return true
        } catch {
            errorMessage = Loadable<Page>.message(for: error)
            return false
        }
    }
}
