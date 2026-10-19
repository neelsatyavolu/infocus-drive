import Foundation
import Observation

/// The Class Board's cycle setting for one visit: which cycle it shows (producers read it,
/// executives change it). The board's PIN lives in Settings → PINs, as on the web.
@MainActor @Observable
final class ClassBoardSettingsModel {
    private(set) var cycle: Loadable<ClassBoardCycleSetting> = .idle
    private(set) var savingCycle = false
    var actionError: String?
    var notice: String?

    func load(api: CommunityAPI) async {
        if cycle.value == nil { cycle = .loading }
        do {
            cycle = .loaded(try await api.classBoardCycle())
        } catch {
            cycle = .failed(Loadable<ClassBoardCycleSetting>.message(for: error))
        }
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

    /// The web's toast after a change.
    nonisolated static func savedNotice(_ number: Int?) -> String {
        number.map { "Class Board shows Cycle \($0)." } ?? "Class Board follows the current cycle."
    }
}

