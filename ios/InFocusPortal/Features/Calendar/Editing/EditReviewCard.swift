import AVKit
import SwiftUI

/// At Review: the edited show with its chapters, anything flagged, then Approve & schedule or
/// Send back. Once the show was sent to YouTube the card stays, read-only.
struct EditReviewCard: View {
    let model: ShowEditModel
    let state: ShowEditState
    let job: ShowEditJob

    @Environment(Router.self) private var router
    /// The publish time the producer ticked as right; a different time unticks it.
    @State private var confirmedAt: String?
    @State private var sendingBack = false
    @State private var fix = ""
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.sentToYouTube ? "The edited show" : "Review").headline(.h3)
                Spacer()
                StatusTag(text: "Version \(job.version)")
            }
            if let error = job.error { EditErrorBanner(message: error) }
            if let preview = state.preview {
                EditedShowPlayer(url: preview.videoUrl, chapters: job.checks?.chapters ?? [])
                    .id("\(job.id)-\(job.version)")
            }
            flagged
            if state.sentToYouTube { FixHistory(conversation: job.conversation) } else { actions }
            EditNote(text: ShowEditRules.details(job, sent: state.sentToYouTube))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private var flagged: some View {
        let flags = job.decisions.filter(\.flagged).map(\.detail) + (job.checks?.failures ?? [])
        if !flags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(state.sentToYouTube ? "Flagged by the editor" : "Check these before scheduling", systemImage: "exclamationmark.triangle")
                    .font(.lexend(14, .medium, relativeTo: .subheadline))
                ForEach(Array(flags.enumerated()), id: \.offset) { _, flag in Text("• " + flag).font(.small) }
                if job.decisions.contains(where: { $0.flagged && $0.kind == "package" }) {
                    Text("Missing a package? Queue it with its final cut in the Publishing Queue, then press Redo automatic edit.")
                        .font(.small)
                    Button("Open the Publishing Queue") { router.push(.publishing(.home)) }
                        .font(.small).foregroundStyle(Brand.green)
                }
            }
            .foregroundStyle(Brand.warning)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.warningTint, in: RoundedRectangle(cornerRadius: Brand.radius))
        }
    }

    @ViewBuilder
    private var actions: some View {
        let approve = state.approve
        let schedulable = approve != nil && approve?.problem == nil
        let confirmed = schedulable && confirmedAt == approve?.publishAt
        if let approve, schedulable {
            Toggle(isOn: Binding(get: { confirmed }, set: { confirmedAt = $0 ? approve.publishAt : nil })) {
                Text("Goes public \(PortalJSON.date(from: approve.publishAt).map(ShowEditRules.pacific) ?? approve.publishAt). That's the right date and time.")
                    .font(.small)
            }
            .tint(Brand.fill)
            .disabled(model.busy != nil)
        }
        Button {
            guard let approve else { return }
            Task { await model.send(.approve(id: job.id, publishAt: approve.publishAt), success: "Approved. Scheduled on YouTube.") }
        } label: {
            if model.busy == "approve" { ProgressView() } else { Label("Approve & schedule", systemImage: "calendar.badge.checkmark") }
        }
        .buttonStyle(.brandPrimary)
        .disabled(model.busy != nil || !confirmed)
        EditNote(text: ShowEditRules.approveLine(approve))
        if state.preview != nil {
            Button("Change details on the Portal") {
                router.openPortal("editing?date=\(model.date)", title: "Editing")
            }
            .font(.small).foregroundStyle(Brand.green)
        }
        EditNote(text: ShowEditRules.autoScheduleNote)
        Button("Send back", systemImage: "arrow.uturn.backward") { sendingBack.toggle() }
            .buttonStyle(.brandSecondary)
            .disabled(model.busy != nil)
        if sendingBack { sendBackForm }
        FixHistory(conversation: job.conversation)
    }

    @ViewBuilder
    private var sendBackForm: some View {
        let text = fix.trimmingCharacters(in: .whitespacesAndNewlines)
        NoteField(label: "What needs to change?", placeholder: "Timecodes help, e.g. At 1:12 the Math Club card is cut off.",
                  text: $fix, max: ShowEditRules.fixMax)
        Toggle("Remember this for future shows", isOn: $remember).font(.small).tint(Brand.fill)
        Button {
            Task {
                if await model.send(.fix(id: job.id, text: text, remember: remember), success: "Sent back. The editor will make a new version.") {
                    sendingBack = false
                    fix = ""
                    remember = false
                }
            }
        } label: {
            if model.busy == "fix" { ProgressView() } else { Text("Send back to the editor") }
        }
        .buttonStyle(.brandSecondary)
        .disabled(model.busy != nil || text.isEmpty)
    }
}

/// The producers' send-backs and the editor's replies, oldest first.
private struct FixHistory: View {
    let conversation: [ShowEditJob.Message]

    var body: some View {
        if !conversation.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(conversation.enumerated()), id: \.offset) { _, entry in
                    let producer = entry.from == "producer"
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(producer ? "Producer" : "Editor" + (entry.version.map { " · v\($0)" } ?? ""), color: Brand.muted)
                        Text(entry.text).font(.small).foregroundStyle(Brand.foreground)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(producer ? Color.clear : Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(producer ? Brand.line : Color.clear))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// The edited show's player. The screen reloads every 10–60 seconds and each load signs a new
/// link, so the player keeps the link it started with (a new one would restart at 0:00) and only
/// takes the newest when its own stops working, picking up where it was. Chapters jump there.
private struct EditedShowPlayer: View {
    let url: URL
    let chapters: [ShowChapter]

    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if let player { VideoPlayer(player: player) } else { ProgressView().tint(Brand.onBrand) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
            .accessibilityLabel("Edited show")
            if chapters.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chapters, id: \.self) { chapter in
                            Button { jump(to: chapter.start) } label: {
                                HStack(spacing: 6) {
                                    Text(ShowChapter.time(chapter.start)).font(.mono(12)).monospacedDigit().foregroundStyle(Brand.muted)
                                    Text(chapter.title).font(.small).foregroundStyle(Brand.foreground)
                                }
                                .padding(.horizontal, 10)
                                .frame(minHeight: 36)
                                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Jump to \(chapter.title), \(ShowChapter.time(chapter.start))")
                        }
                    }
                }
            }
        }
        .onAppear {
            guard player == nil else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player = AVPlayer(url: url)
        }
        .onChange(of: url) { _, newest in
            guard let player, player.currentItem?.status == .failed else { return }
            let time = player.currentTime()
            let item = AVPlayerItem(url: newest)
            player.replaceCurrentItem(with: item)
            player.seek(to: time)
        }
        .onDisappear { player?.pause() }
    }

    private func jump(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}
