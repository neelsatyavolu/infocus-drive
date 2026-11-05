import AVKit
import SwiftUI

/// A clip or cut on a stage: poster, title, roll and comment counts. Tapping plays it.
struct StageMediaCard: View {
    let media: StageMedia
    /// Set while picking clips to download: the tap ticks instead of playing.
    var ticked: Bool?
    var onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                poster
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: Brand.tagRadius))
                VStack(alignment: .leading, spacing: 6) {
                    Text(media.title)
                        .font(.lexend(15, .medium))
                        .foregroundStyle(Brand.foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let roll = media.rollLabel { StatusTag(text: roll) }
                        if media.isNew == true { StatusTag(text: "New", tone: .warning) }
                        if !media.isReady { StatusTag(text: "Processing", tone: .neutral) }
                        if media.commentCount > 0 {
                            Label("\(media.commentCount)", systemImage: "text.bubble")
                                .font(.mono(12))
                                .foregroundStyle(Brand.muted)
                                .accessibilityLabel("\(media.commentCount) comments")
                        }
                    }
                }
                Spacer(minLength: 0)
                if let ticked {
                    ClipTick(ticked: ticked, enabled: media.isReady)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(media.playbackUrl == nil ? Brand.muted : Brand.green)
                        .accessibilityHidden(true)
                }
            }
            .card(padding: 12)
        }
        .buttonStyle(.plain)
        .disabled(ticked == nil ? media.playbackUrl == nil : !media.isReady)
        .opacity(ticked != nil && !media.isReady ? 0.5 : 1)
        .accessibilityLabel(ClipTick.accessibilityLabel(media, ticked: ticked))
        .accessibilityAddTraits(ticked == true ? .isSelected : [])
    }

    @ViewBuilder private var poster: some View {
        if let url = media.thumbnailUrl {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Brand.raised
            }
        } else {
            ZStack {
                Brand.raised
                Image(systemName: "film").foregroundStyle(Brand.muted)
            }
        }
    }
}

/// The tick at a clip row's end while picking clips to download (the row itself is the toggle).
struct ClipTick: View {
    let ticked: Bool
    let enabled: Bool

    var body: some View {
        Image(systemName: ticked ? "checkmark.square.fill" : "square")
            .font(.system(size: 24))
            .foregroundStyle(ticked ? Brand.green : Brand.muted)
            .opacity(enabled ? 1 : 0.5)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHidden(true)
    }

    static func accessibilityLabel(_ media: StageMedia, ticked: Bool?) -> String {
        guard ticked != nil else { return "\(media.title), \(media.playbackUrl == nil ? "not ready to play" : "play")" }
        return media.isReady ? media.title : "\(media.title), not ready to download"
    }
}

/// Full-screen playback of a stage clip (signed InFocus Drive URL).
struct StagePlayerScreen: View {
    let media: StageMedia
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
                } else {
                    Text("This video isn't ready yet.").font(.bodyText).foregroundStyle(Brand.onBrand)
                }
            }
            .navigationTitle(media.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            guard player == nil, let url = media.playbackUrl else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            let item = AVPlayer(url: url)
            player = item
            item.play()
        }
        .onDisappear { player?.pause() }
    }
}

/// An image the Portal serves only to signed-in members (proofs of contact).
struct PortalImage: View {
    let path: String
    let api: WorkAPI
    /// Show the whole image (a full-screen viewer) instead of filling the frame.
    var fit = false
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Brand.raised
            if let image {
                if fit {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else if failed {
                Image(systemName: "photo").foregroundStyle(Brand.muted)
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            do {
                let data = try await api.data(path)
                image = UIImage(data: data)
                failed = image == nil
            } catch {
                failed = true
            }
        }
    }
}
