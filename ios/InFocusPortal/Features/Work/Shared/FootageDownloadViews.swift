import SwiftUI

/// The Footage section's download actions (the web's Footage panel): Download all (a lone clip as
/// itself, more as one zip), or Select to tick clips for Download N clips. Hidden until a clip is
/// ready; the progress card shows below.
struct FootageDownloadBar: View {
    let rowId: String
    let topic: String
    let media: [StageMedia]
    let downloader: FootageDownloader

    @Environment(\.portalClient) private var client

    var body: some View {
        let ready = FootageFile.readyIDs(media)
        if !ready.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if downloader.selecting {
                        let picked = downloader.picked(in: media)
                        Button("Cancel") { downloader.stopSelecting() }
                            .buttonStyle(.brandSecondary)
                        Button { start(picked) } label: {
                            Label(FootageDownloader.selectionTitle(picked.count), systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.brandPrimary)
                        .disabled(picked.isEmpty)
                    } else {
                        if ready.count > 1 {
                            Button("Select") { downloader.selecting = true }
                                .buttonStyle(.brandSecondary)
                        }
                        Button { start(FootageFile.allIDs(media)) } label: {
                            Label(ready.count == 1 ? "Download" : "Download all", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.brandSecondary)
                    }
                }
                .disabled(downloader.isBusy)
                if downloader.selecting {
                    Text("Tap clips to pick them. Clips still processing can't be picked.")
                        .font(.small).foregroundStyle(Brand.muted)
                }
                FootageDownloadCard(downloader: downloader)
            }
            .hiddenInSampleApp()
        }
    }

    private func start(_ ids: [String]) {
        let single = ids.count == 1 ? media.first { $0.id == ids[0] } : nil
        let label = single?.title ?? (ids.isEmpty ? "All footage" : "\(ids.count) clips")
        let topicName = topic.isEmpty ? "Package" : topic
        downloader.start(rowId: rowId, ids: ids, label: label,
                         fallbackName: single?.title ?? "\(topicName) footage.zip", client: client)
    }
}

/// "Download original" for one ready clip (the web's watch dialog), with its own progress card.
struct DownloadOriginalButton: View {
    let rowId: String
    let clip: StageMedia
    let downloader: FootageDownloader

    @Environment(\.portalClient) private var client

    var body: some View {
        if clip.isReady {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    downloader.start(rowId: rowId, ids: [clip.id], label: clip.title, fallbackName: clip.title, client: client)
                } label: {
                    Label("Download original", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.brandSecondary)
                .disabled(downloader.isBusy)
                FootageDownloadCard(downloader: downloader)
            }
            .hiddenInSampleApp()
        }
    }
}

/// Download progress with Cancel, or why it failed.
struct FootageDownloadCard: View {
    let downloader: FootageDownloader

    var body: some View {
        switch downloader.phase {
        case .idle:
            EmptyView()
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    // A zip's size isn't known up front: a spinner instead of a bar.
                    if total == nil { ProgressView().controlSize(.small) }
                    Text(downloader.label).font(.lexend(14, .medium)).lineLimit(1)
                    Spacer()
                    Text(FootageDownloader.progressText(received: received, total: total))
                        .font(.mono(13))
                        .monospacedDigit()
                        .foregroundStyle(Brand.muted)
                }
                if let total {
                    ProgressView(value: Double(min(received, total)), total: Double(total)).tint(Brand.fill)
                }
                HStack {
                    Text("Keep InFocus open until the download finishes.").font(.small).foregroundStyle(Brand.muted)
                    Spacer(minLength: 8)
                    Button("Cancel") { downloader.cancel() }
                        .font(.lexend(14, .medium))
                        .foregroundStyle(Brand.green)
                        .frame(minHeight: 44)
                }
            }
            .card()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Downloading \(downloader.label), \(FootageDownloader.progressText(received: received, total: total))")
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").font(.small).foregroundStyle(Brand.danger)
                Spacer(minLength: 8)
                Button("Dismiss") { downloader.dismissError() }
                    .font(.small)
                    .foregroundStyle(Brand.muted)
                    .frame(minHeight: 44)
            }
            .card()
        }
    }
}
