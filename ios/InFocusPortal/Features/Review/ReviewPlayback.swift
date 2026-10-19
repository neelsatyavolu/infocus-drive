import AVKit
import Observation
import SwiftUI

/// The video under review: an AVPlayer on the version's signed URL, its playhead
/// (for timecoded comments) and seeking (tapping a comment jumps to it).
@MainActor @Observable
final class ReviewPlayback {
    private(set) var player: AVPlayer?
    private(set) var currentTime: Double = 0
    private(set) var state: Loadable<URL> = .idle
    private var observer: Any?
    private var loadedVersion: String?

    func load(mediaId: String, version: ReviewVersion, api: ReviewAPI) async {
        guard loadedVersion != version.id else { return }
        teardown()
        loadedVersion = version.id
        guard version.isReady else {
            state = .failed(version.status == .failed ? "This version didn't finish processing." : "This version is still processing.")
            return
        }
        state = .loading
        do {
            let token = try await api.playback(mediaId, version.id)
            guard loadedVersion == version.id else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            let player = AVPlayer(url: token.playbackUrl)
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.currentTime = time.seconds.isFinite ? time.seconds : 0 }
            }
            self.player = player
            state = .loaded(token.playbackUrl)
        } catch PortalError.sampleApp {
            state = .failed("Video playback isn't part of the sample app.")
        } catch {
            state = .failed(Loadable<URL>.message(for: error))
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, seconds)
    }

    func pause() { player?.pause() }

    func teardown() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        loadedVersion = nil
        currentTime = 0
        state = .idle
    }
}

/// The video player area, 16:9.
struct ReviewVideoView: View {
    let playback: ReviewPlayback

    var body: some View {
        ZStack {
            Color.black
            switch playback.state {
            case .loaded:
                if let player = playback.player { VideoPlayer(player: player) }
            case .idle, .loading:
                ProgressView().tint(Brand.onBrand)
            case .failed(let message):
                Text(message)
                    .font(.small)
                    .foregroundStyle(Brand.onBrand)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }
}

/// An image under review. Tap to drop a pin for a comment; pins of known comments show
/// as numbered marks (the web's frame pins, in percent of the image).
struct ReviewImageView: View {
    let data: Data?
    let pins: [ReviewComment]
    @Binding var draftPin: CGPoint?
    var selectedId: String?
    let canPin: Bool

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .overlay {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { location in
                                    guard canPin, geometry.size.width > 0, geometry.size.height > 0 else { return }
                                    draftPin = CGPoint(x: min(100, max(0, location.x / geometry.size.width * 100)),
                                                       y: min(100, max(0, location.y / geometry.size.height * 100)))
                                }
                            ForEach(Array(pins.enumerated()), id: \.element.id) { index, comment in
                                if let x = comment.xPct, let y = comment.yPct {
                                    PinMark(text: "\(index + 1)", selected: comment.id == selectedId)
                                        .position(x: x / 100 * geometry.size.width, y: y / 100 * geometry.size.height)
                                }
                            }
                            if let draftPin {
                                PinMark(text: "+", selected: true)
                                    .position(x: draftPin.x / 100 * geometry.size.width, y: draftPin.y / 100 * geometry.size.height)
                            }
                        }
                    }
                }
                .accessibilityLabel(canPin ? "Image. Tap to place a pin for a comment." : "Image")
        } else {
            ZStack {
                Brand.raised
                ProgressView()
            }
            .aspectRatio(4 / 3, contentMode: .fit)
        }
    }
}

/// A square pin mark on an image.
struct PinMark: View {
    let text: String
    var selected = false

    var body: some View {
        Text(text)
            .font(.mono(12, .medium))
            .foregroundStyle(Brand.onBrand)
            .frame(width: 26, height: 26)
            .background(selected ? Brand.fill : Brand.ink.opacity(0.8), in: RoundedRectangle(cornerRadius: Brand.tagRadius))
            .overlay(RoundedRectangle(cornerRadius: Brand.tagRadius).strokeBorder(Brand.onBrand, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}
