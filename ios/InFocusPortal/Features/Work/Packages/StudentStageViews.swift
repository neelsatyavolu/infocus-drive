import AVKit
import SwiftUI

/// "Where it stands": the next-step sentence, the Initial Cut approval path,
/// then the stage's upload rule (or the Final Cut once-only warning).
struct WhereItStandsCard: View {
    let nextStep: String
    var approvalSteps: [StageGuide.ApprovalStep]?
    var rule: String?
    var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Where it stands")
            Text(nextStep).font(.bodyText).foregroundStyle(Brand.foreground).fixedSize(horizontal: false, vertical: true)
            if let approvalSteps {
                Eyebrow("Approval path", color: Brand.muted)
                ForEach(approvalSteps) { step in ApprovalStepRow(step: step) }
            }
            if let rule {
                Text(rule).font(.small).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.small)
                    .foregroundStyle(Brand.warning)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.warningTint, in: RoundedRectangle(cornerRadius: Brand.radius))
            }
        }
        .card()
    }
}

private struct ApprovalStepRow: View {
    let step: StageGuide.ApprovalStep

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Brand.tagRadius)
                    .fill(step.state == .done ? Brand.greenTint : Brand.raised)
                if step.state == .done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.green)
                } else {
                    Text("\(step.number)").font(.mono(13, .medium)).foregroundStyle(step.state == .current ? Brand.foreground : Brand.muted)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stage \(step.number)").font(.small).foregroundStyle(Brand.muted)
                Text(step.label).font(.lexend(15, step.state == .current ? .semibold : .regular))
                    .foregroundStyle(step.state == .upcoming ? Brand.muted : Brand.foreground)
            }
            Spacer(minLength: 0)
            if let label = step.stateLabel { StatusTag(text: label, tone: step.tone) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One clip or cut: poster, title, tags. Tapping plays it (or opens the clip with its notes).
struct StudentMediaRow: View {
    let media: StageMedia
    var result: (label: String, tone: StatusTag.Tone)?
    var current = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
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
                    FlowTags(media: media, result: result, current: current)
                }
                Spacer(minLength: 0)
                Image(systemName: media.playbackUrl == nil ? "film" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(media.playbackUrl == nil ? Brand.muted : Brand.green)
                    .accessibilityHidden(true)
            }
            .card(padding: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(media.title), \(media.playbackUrl == nil ? "not ready to play" : "play")")
    }

    @ViewBuilder private var poster: some View {
        if let url = media.thumbnailUrl {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Brand.raised }
        } else {
            ZStack {
                Brand.raised
                Image(systemName: "film").foregroundStyle(Brand.muted)
            }
        }
    }
}

private struct FlowTags: View {
    let media: StageMedia
    let result: (label: String, tone: StatusTag.Tone)?
    let current: Bool

    var body: some View {
        HStack(spacing: 6) {
            if current { StatusTag(text: "Current", tone: .success) }
            if let result { StatusTag(text: result.label, tone: result.tone) }
            if !media.isReady {
                StatusTag(text: StageGuide.mediaStatusLabel(media.status), tone: media.status == "FAILED" ? .danger : .neutral)
            }
            if media.commentCount > 0 {
                Label("\(media.commentCount)", systemImage: "text.bubble")
                    .font(.mono(12))
                    .foregroundStyle(Brand.muted)
                    .accessibilityLabel("\(media.commentCount) comments")
            }
        }
    }
}

/// One A-roll/B-roll clip: the video, then the producer's notes on that clip.
struct ClipScreen: View {
    let media: StageMedia
    let rowId: String
    let api: WorkAPI
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ZStack {
                        Color.black
                        if let player {
                            VideoPlayer(player: player)
                        } else {
                            Text("This clip isn't ready to play yet.").font(.small).foregroundStyle(Brand.onBrand)
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
                    if let roll = media.rollLabel { StatusTag(text: roll) }
                    StageCommentsSection(rowId: rowId, stage: StudentStage.aRoll.rawValue, canPost: false, api: api, clipId: media.id)
                }
                .padding(Brand.gutter)
            }
            .brandBackground()
            .navigationTitle(media.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            guard player == nil, let url = media.playbackUrl else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause() }
    }
}
