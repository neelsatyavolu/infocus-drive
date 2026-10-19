import AVKit
import SwiftUI

/// Watching one A-roll/B-roll clip with its own notes (the website's `WatchClipDialog`).
/// A producer's note on a clip asks the group for changes, as on the website.
struct ClipReviewScreen: View {
    let rowId: String
    let clip: StageMedia
    let canComment: Bool
    var onPosted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        Color.black
                        if let player {
                            VideoPlayer(player: player)
                        } else {
                            Text("This video isn't ready yet.").font(.bodyText).foregroundStyle(Brand.onBrand)
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
                    HStack(spacing: 6) {
                        if let roll = clip.rollLabel { StatusTag(text: roll) }
                        if clip.isNew == true { StatusTag(text: "New since your request", tone: .success) }
                    }
                    GroupFeedbackSection(rowId: rowId, stage: GroupStage.aRoll.rawValue, canPost: canComment, clip: clip,
                                         title: "Notes on this clip",
                                         composerHint: "Posting a note asks the group for changes. Students are emailed.",
                                         onPosted: onPosted)
                }
                .padding(Brand.gutter)
            }
            .brandBackground()
            .navigationTitle(clip.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            guard player == nil, let url = clip.playbackUrl else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause() }
    }
}
