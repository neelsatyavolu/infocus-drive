import Observation
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

/// One upload to a package stage: ask the Portal where the file goes, stream it
/// to InFocus Drive, then tell the Portal it's done. Keeps the screen awake
/// meanwhile (like the website's wake lock), since leaving the app pauses it.
@MainActor @Observable
final class StageUploader {
    enum Phase: Equatable {
        case idle
        case preparing
        case uploading(Double)
        case finishing
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var fileName = ""

    var isBusy: Bool {
        switch phase {
        case .preparing, .uploading, .finishing: true
        default: false
        }
    }

    func upload(_ file: URL, request: StageUploadRequest, api: WorkAPI) async -> Bool {
        fileName = request.fileName
        phase = .preparing
        UIApplication.shared.isIdleTimerDisabled = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "InFocus upload")
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            UIApplication.shared.endBackgroundTask(background)
        }
        do {
            let ticket = try await api.startUpload(request)
            phase = .uploading(0)
            try await DriveUploader.upload(file: file, to: ticket.upload) { [weak self] fraction in
                self?.phase = .uploading(fraction)
            }
            phase = .finishing
            try await api.finishUpload(request, ticket)
            phase = .done
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? FileManager.default.removeItem(at: file)
            return true
        } catch {
            phase = .failed(Loadable<Void>.message(for: error))
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    func reset() { phase = .idle }

    func fail(_ message: String) { phase = .failed(message) }
}

/// A video from Photos, copied to a temporary file so it can be streamed.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// The Portal's rules for Final Cut headlines and anchor tosses.
enum PackageText {
    static let headlineMax = 100
    static let tossMax = 500

    static func headlineError(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Add a headline for your package." }
        if trimmed.count > headlineMax { return "Keep the headline to \(headlineMax) characters or fewer." }
        if trimmed.contains("<") || trimmed.contains(">") { return "The headline can't include < or >." }
        return nil
    }

    static func tossError(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Add a toss for the anchors." }
        if trimmed.count > tossMax { return "Keep the toss to \(tossMax) characters or fewer." }
        if trimmed.contains(where: { "<>[]{}".contains($0) }) { return "The toss can't include < > [ ] { }." }
        return nil
    }

    /// A-roll files up to 30 GB, B-roll up to 15 GB (the Portal's limits).
    static func rollSizeError(kind: String, bytes: Int) -> String? {
        let maxGB = kind == "a-roll" ? 30 : 15
        return bytes > maxGB * 1_073_741_824 ? "\(kind == "a-roll" ? "A-roll" : "B-roll") files must be \(maxGB) GB or smaller." : nil
    }
}

/// Progress of the current upload.
struct UploadProgressCard: View {
    let uploader: StageUploader

    var body: some View {
        switch uploader.phase {
        case .idle:
            EmptyView()
        case .preparing, .finishing:
            HStack(spacing: 12) {
                ProgressView()
                Text(uploader.phase == .preparing ? "Starting upload…" : "Finishing…").font(.bodyText)
            }
            .card()
        case .uploading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(uploader.fileName).font(.lexend(14, .medium)).lineLimit(1)
                    Spacer()
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.mono(14, .medium))
                        .monospacedDigit()
                }
                ProgressView(value: fraction).tint(Brand.fill)
                Text("Keep InFocus open until the upload finishes.").font(.small).foregroundStyle(Brand.muted)
            }
            .card()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Uploading \(uploader.fileName), \(Int(fraction * 100)) percent")
        case .done:
            Label("Uploaded", systemImage: "checkmark.circle.fill").font(.bodyText).foregroundStyle(Brand.green).card()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.small).foregroundStyle(Brand.danger).card()
        }
    }
}
