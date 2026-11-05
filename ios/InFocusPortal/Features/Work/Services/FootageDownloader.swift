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

    /// The running download. Held in a box that cancels it when this downloader goes away (its
    /// screen closed), so a multi-GB zip doesn't keep going with no Cancel button.
    private let running = RunningTask()
    /// Bumped by every start and cancel: a cancelled task's late `finish` must not touch the next one.
    private var generation = 0
    /// This downloader's last finished file, removed when it starts again or goes away.
    private var lastFile: URL? { didSet { running.lastFolder = lastFile?.deletingLastPathComponent() } }
    private let onUnauthorized: @Sendable () async -> Void

    init(onUnauthorized: @escaping @Sendable () async -> Void = { await AppModel.shared.sessionEnded() }) {
        self.onUnauthorized = onUnauthorized
    }

    var isBusy: Bool { running.task != nil }

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
        guard running.task == nil else { return }
        self.label = label
        phase = .downloading(received: 0, total: nil)
        generation += 1
        let mine = generation
        // Only this downloader's own last file: another screen's may still be in its share sheet.
        if let lastFile { try? FileManager.default.removeItem(at: lastFile.deletingLastPathComponent()) }
        lastFile = nil
        let path = FootageFile.path(rowId: rowId)
        running.task = Task { [weak self] in
            do {
                if SampleMode.isOn && !SampleMode.allows(path) { throw PortalError.sampleApp }
                var request = await client.request("GET", path, query: FootageFile.query(ids))
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                let file = try await FootageFile.download(request, fallbackName: fallbackName, session: session) { received, total in
                    self?.progress(received, total, from: mine)
                }
                try Task.checkCancellation()
                guard let self, self.generation == mine else {
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                    return
                }
                self.lastFile = file
                self.finish(.idle, from: mine)
                self.stopSelecting()
                share(file)
            } catch is CancellationError {
                self?.finish(.idle, from: mine)
            } catch PortalError.unauthorized {
                guard self?.generation == mine else { return }
                self?.finish(.idle, from: mine)
                await self?.onUnauthorized()
            } catch {
                self?.finish(.failed(Loadable<Void>.message(for: error)), from: mine)
            }
        }
    }

    func cancel() {
        generation += 1
        running.task?.cancel()
        running.task = nil
        phase = .idle
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    private func progress(_ received: Int64, _ total: Int64?, from download: Int) {
        guard download == generation, running.task != nil else { return }
        phase = .downloading(received: received, total: total)
    }

    private func finish(_ next: Phase, from download: Int) {
        guard download == generation else { return }
        running.task = nil
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

/// Cancels the download and removes the last finished file when its downloader is released.
private final class RunningTask: @unchecked Sendable {
    var task: Task<Void, Never>?
    var lastFolder: URL?

    deinit {
        task?.cancel()
        if let lastFolder { try? FileManager.default.removeItem(at: lastFolder) }
    }
}
