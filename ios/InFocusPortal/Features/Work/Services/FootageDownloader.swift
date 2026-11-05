import Foundation
import Observation

/// The Footage panel's downloads (the web's `useFootageDownload`): Select mode ticks ready clips,
/// and one download at a time streams to disk with progress and Cancel, then opens the share
/// sheet (Save to Files, Save Video, AirDrop).
@Observable @MainActor
final class FootageDownloader {
    enum Phase: Equatable {
        case idle
        case downloading(received: Int64, total: Int64?)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// What's downloading ("3 clips", the clip's title), for the progress card.
    private(set) var label = ""
    var selecting = false
    private(set) var selected: Set<String> = []

    private var task: Task<Void, Never>?
    private let onUnauthorized: @Sendable () async -> Void

    init(onUnauthorized: @escaping @Sendable () async -> Void = { await AppModel.shared.sessionEnded() }) {
        self.onUnauthorized = onUnauthorized
    }

    var isBusy: Bool { task != nil }

    // MARK: Selecting

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func stopSelecting() {
        selecting = false
        selected = []
    }

    /// The ticked clips that are still ready (clips removed since they were ticked drop out).
    func picked(in media: [StageMedia]) -> [String] {
        FootageFile.readyIDs(media).filter(selected.contains)
    }

    // MARK: Downloading

    /// `ids` empty means every ready clip as one zip. `fallbackName` names the file when the
    /// server doesn't.
    func start(rowId: String, ids: [String], label: String, fallbackName: String, client: PortalClient,
               session: URLSession = FootageFile.session, share: @escaping @MainActor (URL) -> Void = { Presenter.share($0) }) {
        guard task == nil else { return }
        self.label = label
        phase = .downloading(received: 0, total: nil)
        let path = FootageFile.path(rowId: rowId)
        task = Task { [weak self] in
            do {
                if SampleMode.isOn && !SampleMode.allows(path) { throw PortalError.sampleApp }
                var request = await client.request("GET", path, query: FootageFile.query(ids))
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                try? FileManager.default.removeItem(at: FootageFile.folder)
                let file = try await FootageFile.download(request, fallbackName: fallbackName, session: session) { received, total in
                    self?.progress(received, total)
                }
                try Task.checkCancellation()
                self?.finish(.idle)
                self?.stopSelecting()
                share(file)
            } catch is CancellationError {
                self?.finish(.idle)
            } catch PortalError.unauthorized {
                self?.finish(.idle)
                await self?.onUnauthorized()
            } catch {
                self?.finish(.failed(Loadable<Void>.message(for: error)))
            }
        }
    }

    func cancel() {
        task?.cancel()
        finish(.idle)
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    private func progress(_ received: Int64, _ total: Int64?) {
        guard task != nil else { return }
        phase = .downloading(received: received, total: total)
    }

    private func finish(_ next: Phase) {
        task = nil
        phase = next
    }

    /// "1.2 GB of 3.4 GB", or just what's in so far when the size isn't known (a zip).
    static func progressText(received: Int64, total: Int64?) -> String {
        let style = ByteCountFormatter.CountStyle.file
        let done = ByteCountFormatter.string(fromByteCount: received, countStyle: style)
        guard let total else { return done }
        return "\(done) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: style))"
    }

    /// "Download 3 clips", or "Download" while nothing is ticked.
    static func selectionTitle(_ count: Int) -> String {
        count == 0 ? "Download" : "Download \(count) \(count == 1 ? "clip" : "clips")"
    }
}
