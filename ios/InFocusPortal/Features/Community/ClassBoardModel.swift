import Foundation
import Observation

/// The Class Board on screen. It refreshes every 30 seconds while open, as the web board does,
/// and keeps the last board when a refresh fails (marking it stale).
@MainActor @Observable
final class ClassBoardModel {
    static let refreshInterval: Duration = .seconds(30)

    private(set) var state: Loadable<ClassBoard> = .idle
    /// A refresh failed after the board loaded; the board on screen is older than it says.
    private(set) var stale = false

    func load(api: CommunityAPI) async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.classBoard())
            stale = false
        } catch is CancellationError {
            return
        } catch {
            if state.value == nil {
                state = .failed(Loadable<ClassBoard>.message(for: error))
            } else {
                stale = true
            }
        }
    }

    /// Refreshes until the task is cancelled (the screen goes away).
    func keepFresh(api: CommunityAPI) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.refreshInterval)
            if Task.isCancelled { return }
            await load(api: api)
        }
    }
}
