import SwiftUI

/// Reviewing one video or image: play it, switch versions, set its approval status,
/// and comment at a moment (video) or a spot (image). Tapping a comment seeks to it.
struct ReviewScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.portalClient) private var client
    @State private var model: ReviewModel
    @State private var playback = ReviewPlayback()
    @State private var imageData: Data?
    @State private var draftPin: CGPoint?
    @State private var selectedId: String?
    @State private var editing: ReviewComment?
    @State private var editText = ""
    @State private var deleting: ReviewComment?
    @State private var airing = false

    init(projectId: String, mediaId: String, versionId: String?) {
        _model = State(initialValue: ReviewModel(projectId: projectId, mediaId: mediaId, versionId: versionId))
    }

    private var api: ReviewAPI { .resolve(client) }

    var body: some View {
        LoadableView(model.state, retry: { Task { await model.load(api) } }) { loaded in
            content(loaded)
        }
        .brandBackground()
        .navigationTitle(model.media?.title ?? "Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { if model.state.value == nil { await model.load(api) } }
        .task(id: model.version?.id) { await loadVersion() }
        .onDisappear { playback.pause() }
        .modifier(ReviewDialogs(model: model, api: api, editing: $editing, editText: $editText, deleting: $deleting, airing: $airing))
    }

    private func content(_ loaded: ReviewModel.Loaded) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                media
                header(loaded)
                if let version = model.version {
                    ReviewComposer(isImage: version.isImage, currentTime: playback.currentTime, draftPin: $draftPin, busy: model.busy) { body, atTime in
                        let posted = await model.post(body, time: !version.isImage && atTime ? playback.currentTime : nil,
                                                      pin: version.isImage ? draftPin : nil, api: api)
                        if posted { draftPin = nil }
                        return posted
                    }
                    .padding(.horizontal, Brand.gutter)
                }
                comments
                    .padding(.horizontal, Brand.gutter)
            }
            .padding(.bottom, 24)
        }
        .refreshable { await model.load(api) }
    }

    @ViewBuilder private var media: some View {
        if let version = model.version {
            if version.isImage {
                ReviewImageView(data: imageData, pins: model.threads.map(\.root).filter { $0.targetType == .framePin },
                                draftPin: $draftPin, selectedId: selectedId, canPin: true)
            } else {
                ReviewVideoView(playback: playback)
            }
        }
    }

    private func header(_ loaded: ReviewModel.Loaded) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(loaded.shell.projectName)
            Text(loaded.media.title).headline(.h2)
            HStack(spacing: 8) {
                if loaded.media.versions.count > 1 {
                    Menu {
                        ForEach(loaded.media.versions) { version in
                            Button("Version \(version.versionNumber)") { model.select(version) }
                        }
                    } label: {
                        Label("Version \(model.version?.versionNumber ?? 1)", systemImage: "chevron.up.chevron.down")
                            .font(.lexend(14, .medium))
                    }
                    .frame(minHeight: 44)
                } else if let version = model.version {
                    Text("Version \(version.versionNumber)").font(.lexend(14, .medium)).foregroundStyle(Brand.secondary)
                }
                Spacer()
                if let version = model.version { approval(version) }
            }
            if !loaded.media.assignees.isEmpty {
                Label(loaded.media.assignees.joined(separator: ", "), systemImage: "person.2")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
            }
        }
        .padding(.horizontal, Brand.gutter)
    }

    @ViewBuilder
    private func approval(_ version: ReviewVersion) -> some View {
        let tag = StatusTag(text: ReviewLogic.label(version.approvalStatus),
                            tone: version.approvalStatus == .needsChanges ? .warning : version.approvalStatus == .inReview ? .neutral : .success)
        if session.user?.isProducer == true {
            Menu {
                ForEach(ReviewLogic.transitions(from: version.approvalStatus), id: \.self) { status in
                    Button(ReviewLogic.label(status)) {
                        if status == .aired { airing = true } else { Task { await model.setApproval(status, airedAt: nil, api: api) } }
                    }
                }
            } label: {
                HStack(spacing: 4) { tag; Image(systemName: "chevron.down").font(.caption).foregroundStyle(Brand.muted) }
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("Status: \(ReviewLogic.label(version.approvalStatus)). Change status")
        } else {
            tag
        }
    }

    @ViewBuilder private var comments: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Comments")
            if !model.hasEarlierComments {
                earlierCommentsLink
            }
            if model.threads.isEmpty && model.hasEarlierComments {
                EmptyStateView(title: "No comments yet", message: "Be the first to leave a note on this version.")
            }
            ForEach(Array(model.threads.enumerated()), id: \.element.id) { index, thread in
                ReviewThreadView(
                    thread: thread, number: pinNumber(thread, index: index), selected: selectedId == thread.id,
                    canResolve: ReviewLogic.canResolve(role: model.role, own: model.isOwn(thread.root)),
                    canDelete: { ReviewLogic.canDelete(role: model.role, own: model.isOwn($0)) },
                    canEdit: { model.isOwn($0) },
                    onSelect: { select(thread.root) },
                    onReply: { await model.reply(to: thread, $0, api: api) },
                    onResolve: { Task { await model.toggleResolved(thread.root, api: api) } },
                    onEdit: { comment in
                        editText = comment.body
                        editing = comment
                    },
                    onDelete: { deleting = $0 }
                )
            }
        }
    }

    /// Live accounts: the Portal can't list earlier comments to the app, so they open on the website.
    private var earlierCommentsLink: some View {
        Button {
            playback.pause()
            router.openPortal(ReviewLogic.reviewPath(projectId: model.projectId, mediaId: model.mediaId, versionId: model.version?.id),
                              title: model.media?.title)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble").foregroundStyle(Brand.green).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Earlier comments").font(.lexend(15, .medium)).foregroundStyle(Brand.foreground)
                    Text("Comments from before you opened this are on the Portal page.").font(.small).foregroundStyle(Brand.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Brand.muted).accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .card(padding: 12)
        }
        .buttonStyle(.plain)
        .hiddenInSampleApp()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if !SampleMode.isOn {
                Menu {
                    Button {
                        playback.pause()
                        router.openPortal(ReviewLogic.reviewPath(projectId: model.projectId, mediaId: model.mediaId,
                                                                 versionId: model.version?.id), title: model.media?.title)
                    } label: { Label("Open on the Portal", systemImage: "safari") }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("More")
            }
        }
    }

    private func pinNumber(_ thread: ReviewLogic.Thread, index: Int) -> Int {
        let pins = model.threads.filter { $0.root.targetType == .framePin }
        return (pins.firstIndex { $0.id == thread.id } ?? index) + 1
    }

    private func select(_ comment: ReviewComment) {
        selectedId = comment.id
        if comment.targetType == .timecode { playback.seek(to: comment.timeSeconds) }
    }

    private func loadVersion() async {
        guard let version = model.version else { return }
        draftPin = nil
        if version.isImage {
            playback.teardown()
            imageData = nil
            imageData = try? await api.image(model.mediaId, version.id)
        } else {
            await playback.load(mediaId: model.mediaId, version: version, api: api)
        }
    }
}

/// Edit and delete confirmations, the aired date, and errors.
private struct ReviewDialogs: ViewModifier {
    let model: ReviewModel
    let api: ReviewAPI
    @Binding var editing: ReviewComment?
    @Binding var editText: String
    @Binding var deleting: ReviewComment?
    @Binding var airing: Bool

    func body(content: Content) -> some View {
        content
            .alert("Edit comment", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Comment", text: $editText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let comment = editing { Task { await model.edit(comment, to: editText, api: api) } } }
            }
            .confirmationDialog("Delete this comment?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { comment in
                Button("Delete", role: .destructive) { Task { await model.delete(comment, api: api) } }
            } message: { comment in
                Text(comment.isReply ? "The reply is removed." : "Its replies are removed too.")
            }
            .sheet(isPresented: $airing) {
                AiredDateSheet { date in Task { await model.setApproval(.aired, airedAt: date, api: api) } }
            }
            .alert("Couldn't finish that", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
    }
}
