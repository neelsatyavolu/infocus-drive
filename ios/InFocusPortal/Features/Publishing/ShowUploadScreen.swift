import SwiftUI

/// The whole show's YouTube upload for one air date (producers): status,
/// progress while it uploads, when it goes public, and any problem. The
/// upload itself (a large show file plus title and season) starts from The
/// Show on the web.
struct ShowUploadScreen: View {
    let date: String
    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var state: Loadable<ShowPublicationState> = .idle

    private var service: PublishingService { PublishingService(client: client) }

    var body: some View {
        LoadableView(state, retry: { Task { await load() } }) { show in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Nameplate(eyebrow: "Whole show", title: QueueLogic.showLabel(date),
                              subtitle: show.publication?.title)
                    status(show)
                    Button("Upload or edit in The Show", systemImage: "arrow.up.forward.app") {
                        router.openPortal("show-roles", title: "The Show")
                    }
                    .buttonStyle(.brandSecondary)
                    .hiddenInSampleApp()
                }
                .padding(Brand.gutter)
            }
            .refreshable { await load() }
        }
        .brandBackground()
        .navigationTitle("Show upload")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: date) { await follow() }
    }

    private func status(_ show: ShowPublicationState) -> some View {
        let status = PublicationStatus.show(show.publication)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusTag(text: status.label, tone: status.tone)
                Text(status.detail).font(.small).foregroundStyle(Brand.secondary)
            }
            if !show.configured {
                Label("YouTube publishing isn't set up on the Portal.", systemImage: "info.circle")
                    .font(.small).foregroundStyle(Brand.secondary)
            }
            if let publication = show.publication {
                if let percent = PublicationStatus.percent(uploaded: publication.uploadedBytes, total: publication.totalBytes),
                   publication.status == "UPLOADING" {
                    ProgressView(value: Double(percent), total: 100) {
                        Text("Uploaded").font(.small)
                    } currentValueLabel: {
                        Text("\(percent)%").font(.mono(12)).monospacedDigit()
                    }
                    .tint(Brand.green)
                }
                detailRow("Goes public", publication.publishAt.formatted(date: .abbreviated, time: .shortened))
                if let season = publication.seasonNumber { detailRow("Season", "\(season)") }
                if let error = publication.lastError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle").font(.small).foregroundStyle(Brand.danger)
                }
                if let watch = publication.watchUrl {
                    Link(destination: watch) { Label("Open on YouTube", systemImage: "play.rectangle") }
                        .buttonStyle(.brandPrimary)
                }
            }
        }
        .card()
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.small).foregroundStyle(Brand.muted)
            Spacer()
            Text(value).font(.mono(13)).monospacedDigit().foregroundStyle(Brand.foreground)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await service.showPublication(date: date))
        } catch PortalError.forbidden {
            state = .failed("Show uploads are for producers.")
        } catch {
            if state.value == nil { state = .failed(Loadable<ShowPublicationState>.message(for: error)) }
        }
    }

    /// Loads, then checks again every 10 seconds while YouTube is still working on it.
    private func follow() async {
        await load()
        while !Task.isCancelled, ["UPLOADING", "PROCESSING", "FINALIZING"].contains(state.value?.publication?.status ?? "") {
            try? await Task.sleep(for: .seconds(10))
            await load()
        }
    }
}
