import AVKit
import SwiftUI

/// A clip or cut on a stage: poster, title, roll and comment counts. Tapping plays it.
struct StageMediaCard: View {
    let media: StageMedia
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
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(media.playbackUrl == nil ? Brand.muted : Brand.green)
                    .accessibilityHidden(true)
            }
            .card(padding: 12)
        }
        .buttonStyle(.plain)
        .disabled(media.playbackUrl == nil)
        .accessibilityLabel("\(media.title), \(media.playbackUrl == nil ? "not ready to play" : "play")")
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
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Brand.raised
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
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
