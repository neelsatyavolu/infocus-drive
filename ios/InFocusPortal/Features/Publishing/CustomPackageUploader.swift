import Foundation
import Observation

/// A custom package (a titled video that isn't a package-cycle group): the
/// Portal makes a Drive destination, the video goes straight to InFocus
/// Drive, then the Portal queues it on the next empty show.
@MainActor @Observable
final class CustomPackageUploader {
    enum Phase: Equatable {
        case idle
        case uploading(Double)
        case finishing
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .uploading, .finishing: true
        default: false
        }
    }

    nonisolated static let titleLimit = 150

    /// The title the Portal would accept, or nil if empty.
    nonisolated static func cleanTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(titleLimit))
    }

    func upload(_ file: URL, fileName: String, title rawTitle: String, service: PublishingService) async -> Bool {
        guard let title = Self.cleanTitle(rawTitle) else {
            phase = .failed("Give the package a title.")
            return false
        }
        phase = .uploading(0)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let destination = try await service.startCustomUpload(title: title, fileName: fileName)
            try await DriveUploader.upload(file: file, to: destination.upload) { [weak self] fraction in
                self?.phase = .uploading(fraction)
            }
            phase = .finishing
            try await service.finishCustomUpload(title: title, upload: destination)
            phase = .idle
            return true
        } catch {
            phase = .failed(Loadable<QueuePayload>.message(for: error))
            return false
        }
    }

    func reset() { phase = .idle }
}
