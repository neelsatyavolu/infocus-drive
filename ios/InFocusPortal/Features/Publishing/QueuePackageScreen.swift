import SwiftUI
import UIKit

/// One queued package: its show, final cut poster, YouTube status, and once
/// published the watch link and embed code (what website managers copy).
/// Producers can move, download or remove it, or open its Final Cut in Groups.
struct QueuePackageScreen: View {
    let rowId: String
    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model = PublishingModel()
    @State private var moving: QueuePackage?
    @State private var confirmRemove = false
    @State private var copied = false

    private var service: PublishingService { PublishingService(client: client) }

    var body: some View {
        LoadableView(model.state, retry: { Task { await model.load(service) } }) { payload in
            if let package = model.package(rowId) {
                content(package, canEdit: payload.canEdit)
            } else {
                EmptyStateView(title: "Not in the queue",
                               message: "This package was removed from the Publishing Queue or never queued.",
                               actionTitle: "Open on the web",
                               action: { router.openPortal("publishing-queue/\(rowId)", title: "Package") })
            }
        }
        .brandBackground()
        .navigationTitle("Package")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $moving) { MoveShowSheet(package: $0, model: model, service: service) }
        .confirmationDialog("Remove from the queue?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let package = model.package(rowId) else { return }
                Task { if await model.remove(package, service: service) { dismiss() } }
            }
        } message: {
            Text("Its show date opens up. Anything already sent to YouTube stays there.")
        }
        .publishingAlerts(model)
        .task { await model.load(service) }
        .refreshable { await model.load(service) }
    }

    private func content(_ package: QueuePackage, canEdit: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Nameplate(eyebrow: package.queuedForShowDate.map(QueueLogic.showLabel) ?? "No show yet",
                          title: package.distinctHeadline ?? package.title,
                          subtitle: QueueLogic.subtitle(custom: package.custom, cycleNumber: package.cycleNumber,
                                                        members: package.members))
                if let poster = package.thumbnailUrl { QueuePoster(url: poster) }
                publication(package)
                if canEdit { producerActions(package) }
            }
            .padding(Brand.gutter)
        }
    }

    private func publication(_ package: QueuePackage) -> some View {
        let status = PublicationStatus.package(package.youtubePublication)
        let videoId = package.youtubePublication?.status == "PUBLISHED" ? package.youtubePublication?.videoId : nil
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "YouTube")
            HStack(spacing: 8) {
                StatusTag(text: status.label, tone: status.tone)
                Text(status.detail).font(.small).foregroundStyle(Brand.secondary)
            }
            if let error = package.youtubePublication?.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").font(.small).foregroundStyle(Brand.danger)
            }
            if let videoId, let watch = QueueLogic.watchURL(videoId: videoId) {
                Link(destination: watch) {
                    Label("Watch on YouTube", systemImage: "play.rectangle")
                }
                .buttonStyle(.brandPrimary)
                if let code = QueueLogic.embedCode(videoId: videoId) { embed(code) }
            }
        }
        .card()
    }

    private func embed(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Embed code", color: Brand.muted)
            Text(code)
                .font(.mono(11))
                .foregroundStyle(Brand.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
            Button(copied ? "Copied" : "Copy embed code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = code
                copied = true
            }
            .buttonStyle(.brandSecondary)
            .sensoryFeedback(.success, trigger: copied)
        }
    }

    private func producerActions(_ package: QueuePackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Producer")
            if !package.custom {
                Button("Open Final Cut in Groups", systemImage: "rectangle.stack") {
                    router.push(.work(.group(rowId: package.id, stage: "final-cut")))
                }
                .buttonStyle(.brandSecondary)
            }
            Button("Move to another show", systemImage: "calendar") { moving = package }
                .buttonStyle(.brandSecondary)
            if let date = package.queuedForShowDate {
                Button("Whole show upload", systemImage: "film.stack") { router.push(.publishing(.show(date: date))) }
                    .buttonStyle(.brandSecondary)
            }
            Button("Download final cut", systemImage: "arrow.down.circle") {
                router.openPortal("api/package-cycle/queue/\(package.id)/download", title: "Final cut")
            }
            .buttonStyle(.brandSecondary)
            Button("Remove from queue", systemImage: "trash", role: .destructive) { confirmRemove = true }
                .buttonStyle(QuietDestructiveButtonStyle())
        }
        .disabled(model.busyRowId == package.id)
    }
}
