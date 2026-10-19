import Foundation
import Observation

/// The Class Board's settings for one visit: which cycle it shows (producers read it, executives
/// change it) and its PIN (only shown when the Portal hands it over, as Settings does on the web).
@MainActor @Observable
final class ClassBoardSettingsModel {
    private(set) var cycle: Loadable<ClassBoardCycleSetting> = .idle
    /// Nil until the Portal answers; stays nil for anyone it won't show the PIN to.
    private(set) var pin: ClassBoardPin?
    private(set) var savingCycle = false
    private(set) var renewingPin = false
    var actionError: String?
    var notice: String?

    func load(api: CommunityAPI) async {
        if cycle.value == nil { cycle = .loading }
        async let currentPin = try? await api.classBoardPin()
        do {
            cycle = .loaded(try await api.classBoardCycle())
        } catch {
            cycle = .failed(Loadable<ClassBoardCycleSetting>.message(for: error))
        }
        // Roles can change: a refused PIN hides the PIN section rather than showing an error.
        pin = await currentPin
    }

    /// Saves the cycle (nil follows the current cycle). Returns true when the Portal took it.
    @discardableResult
    func setCycle(_ number: Int?, api: CommunityAPI) async -> Bool {
        guard let current = cycle.value, current.canEdit, !savingCycle, current.cycleNumber != number else { return false }
        savingCycle = true
        defer { savingCycle = false }
        do {
            let saved = try await api.setClassBoardCycle(number)
            var next = current
            next.cycleNumber = saved.cycleNumber
            cycle = .loaded(next)
            notice = Self.savedNotice(saved.cycleNumber)
            return true
        } catch {
            actionError = Loadable<Bool>.message(for: error)
            return false
        }
    }

    /// Creates or replaces the PIN. Returns true when the Portal issued one.
    @discardableResult
    func renewPin(api: CommunityAPI) async -> Bool {
        guard !renewingPin else { return false }
        renewingPin = true
        defer { renewingPin = false }
        do {
            pin = try await api.newClassBoardPin()
            return true
        } catch {
            actionError = Loadable<Bool>.message(for: error)
            return false
        }
    }

    /// The web's toast after a change.
    nonisolated static func savedNotice(_ number: Int?) -> String {
        number.map { "Class Board shows Cycle \($0)." } ?? "Class Board follows the current cycle."
    }
}

