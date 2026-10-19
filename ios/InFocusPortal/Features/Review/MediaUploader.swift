import Observation
import UIKit

/// Adds a video or a photo to a project the way the web does: a video gets an InFocus
/// Drive destination from the Portal, streams there, then the Portal marks it ready;
/// a photo goes up in one form (10 MB at most).
@MainActor @Observable
final class MediaUploader {
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

    /// The title the web gives an upload: the file name without its extension.
    nonisolated static func title(for fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReviewLogic.cleanTitle(base) ?? "Untitled video"
    }

    func uploadVideo(_ file: URL, fileName: String, projectId: String, folderId: String?, api: ReviewAPI) async -> Bool {
        self.fileName = fileName
        phase = .preparing
        UIApplication.shared.isIdleTimerDisabled = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "InFocus upload")
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            UIApplication.shared.endBackgroundTask(background)
            try? FileManager.default.removeItem(at: file)
        }
        do {
            let request = ReviewUploadRequest(projectId: projectId, title: Self.title(for: fileName), fileName: fileName, folderId: folderId)
            let ticket = try await api.startUpload(request)
            guard let drive = ticket.upload.drive else {
                throw DriveUploader.Failed(message: "This project uploads to the old video host. Upload it on the Portal website.")
            }
            phase = .uploading(0)
            try await DriveUploader.upload(file: file, to: drive) { [weak self] fraction in
                self?.phase = .uploading(fraction)
            }
            phase = .finishing
            try await api.finishUpload(ticket.media.id, ticket.version.id)
            return succeed()
        } catch {
            return fail(error)
        }
    }

    func uploadImage(_ data: Data, projectId: String, folderId: String?, api: ReviewAPI) async -> Bool {
        fileName = "Photo"
        phase = .preparing
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else {
            phase = .failed("That photo couldn't be read.")
            return false
        }
        do {
            phase = .finishing
            let title = "Photo \(Date().formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
            try await api.uploadImage(projectId, folderId, title, jpeg)
            return succeed()
        } catch {
            return fail(error)
        }
    }

    func reset() { phase = .idle }

    private func succeed() -> Bool {
        phase = .done
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return true
    }

    private func fail(_ error: Error) -> Bool {
        phase = .failed(Loadable<Void>.message(for: error))
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        return false
    }
}
