import AVFoundation
import Foundation
import Observation
import UIKit

/// Runs one show's upload, step by step like the Portal's dialog: pick a video, it goes to
/// InFocus Drive (a frame is grabbed for the thumbnail meanwhile), review the YouTube details,
/// then schedule it. A show already sent shows its YouTube status, checked every 10 seconds
/// while YouTube is still working on it.
@MainActor @Observable
final class ShowUploadModel {
    enum Phase: Equatable {
        case loading
        case failed(String)
        case pick
        case uploading(Double)
        case review
        case status
    }

    let date: String
    private(set) var phase: Phase = .loading
    private(set) var state: ShowUploadState?
    var form: ShowUploadForm?
    private(set) var thumbnail: Data?
    private(set) var capturing = false
    private(set) var submitting = false
    var thumbnailSeconds = String(ShowUploadRules.thumbnailSeconds)
    /// The last thing that went wrong, in the Portal's words.
    var error: String?

    private let api: ShowUploadAPI
    private var file: URL?

    init(date: String, api: ShowUploadAPI) {
        self.date = date
        self.api = api
    }

    var isUploading: Bool {
        if case .uploading = phase { return true }
        return false
    }

    var seasonHint: String {
        ShowUploadRules.seasonHint(existing: state?.defaults?.existingSeasons, season: form?.seasonNumber ?? "")
    }

    func load() async {
        do {
            let next = try await api.state(date)
            state = next
            phase = next.isSent ? .status : .pick
        } catch PortalError.forbidden {
            phase = .failed("Show uploads are for producers.")
        } catch {
            phase = .failed(CalendarDayEditor.message(for: error))
        }
    }

    /// Reloads while YouTube is still uploading or processing.
    func follow() async {
        while !Task.isCancelled, phase == .status, ShowUploadRules.active.contains(state?.publication?.status ?? "") {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let next = try? await api.state(date) else { continue }
            state = next
        }
    }

    /// Sends a picked video (a temporary copy this model now owns) to InFocus Drive, then opens the review.
    func upload(_ picked: URL, fileName: String) async {
        removeFile()
        file = picked
        thumbnail = nil
        error = nil
        phase = .uploading(0)
        Task { await retakeThumbnail(seconds: ShowUploadRules.thumbnailSeconds) }
        do {
            let drive = try await api.start(date, fileName)
            try await api.send(picked, drive) { [weak self] fraction in
                if case .uploading = self?.phase { self?.phase = .uploading(fraction) }
            }
            let next = try await api.state(date)
            state = next
            guard let defaults = next.defaults else { throw EditError("This show was already sent to YouTube.") }
            form = ShowUploadForm(defaults)
            phase = .review
        } catch {
            self.error = CalendarDayEditor.message(for: error)
            phase = .pick
        }
    }

    func retake() async {
        let seconds = max(0, Double(thumbnailSeconds.trimmingCharacters(in: .whitespaces)) ?? 0)
        await retakeThumbnail(seconds: seconds)
    }

    private func retakeThumbnail(seconds: Double) async {
        guard let file else { return }
        capturing = true
        defer { capturing = false }
        do {
            thumbnail = try await ShowThumbnail.capture(file, seconds: seconds)
        } catch {
            self.error = "Could not grab a frame there. Try another time, or YouTube will pick one."
        }
    }

    func chooseAnotherFile() {
        phase = .pick
    }

    /// Saves the thumbnail, then schedules the show on YouTube.
    func schedule() async {
        guard let form else { return }
        guard let body = form.confirmBody(showDate: date) else {
            error = form.problem
            return
        }
        submitting = true
        error = nil
        defer { submitting = false }
        do {
            if let thumbnail { try await api.savePoster(date, thumbnail) }
            state = try await api.confirm(body)
            phase = .status
            removeFile()
        } catch {
            self.error = CalendarDayEditor.message(for: error)
        }
    }

    func removeFile() {
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}

/// The frame YouTube gets as the thumbnail: exact time, at most 1280 wide, a JPEG under 2 MB.
enum ShowThumbnail {
    static func capture(_ file: URL, seconds: Double) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: ShowUploadRules.thumbnailMaxWidth, height: ShowUploadRules.thumbnailMaxWidth)
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return try jpeg(UIImage(cgImage: image))
    }

    static func jpeg(_ image: UIImage) throws -> Data {
        for quality in [0.85, 0.7, 0.55, 0.4] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= ShowUploadRules.posterMaxBytes { return data }
        }
        throw EditError("The thumbnail is too large.")
    }
}
