import PhotosUI
import SwiftUI

/// A student's A-roll/B-roll, Initial Cut or Final Cut, native end to end like the
/// website's stage page: status, where it stands (next step, Initial Cut approval
/// path, upload rules), uploads from Photos or Files to InFocus Drive, the clips
/// or versions, what airs (headline and toss), Package of the Cycle, and feedback.
struct StudentStageScreen: View {
    let stage: StudentStage

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var state: Loadable<StageView> = .idle
    @State private var uploader = StageUploader()
    @State private var playing: StageMedia?
    @State private var openClip: StageMedia?
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var rollKind = "a-roll"
    @State private var finalCutDetails: FinalCutDetails?
    @State private var askFinalCut = false
    @State private var editToss = false
    @State private var savingToss = false
    @State private var pendingFinalCut: StageUploadFile?
    @State private var notice: (String, Bool)?
    @State private var refreshKey = 0
    @State private var showOlder = false

    var body: some View {
        ScrollView {
            LoadableView(state, retry: { Task { await load() } }) { view in
                VStack(alignment: .leading, spacing: 20) {
                    if view.empty || view.row == nil {
                        EmptyStateView(title: "Not on a package yet", message: "This stage opens when your group is on the roster.").card()
                    } else if view.unlocked == false {
                        EmptyStateView(title: "\(stage.title) is locked", message: StageGuide.lockedSentence(stage)).card()
                    } else if let row = view.row {
                        content(view, row: row)
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await load() }
        .brandBackground()
        .navigationTitle(stage.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if state.value == nil { await load() } }
        .fullScreenCover(item: $playing) { StagePlayerScreen(media: $0) }
        .sheet(item: $openClip, onDismiss: { Task { await load() } }) { clip in
            ClipScreen(media: clip, rowId: state.value?.row?.id ?? "", api: api)
        }
        .photosPicker(isPresented: $showPhotos, selection: $pickedItems, maxSelectionCount: stage == .aRoll ? nil : 1,
                      matching: .videos)
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            pickedItems = []
            Task { await importPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video, .audiovisualContent],
                      allowsMultipleSelection: stage == .aRoll) { result in
            guard case .success(let urls) = result else { return }
            Task { await importFiles(urls) }
        }
        .sheet(isPresented: $askFinalCut) {
            FinalCutDetailsSheet(initialHeadline: finalCutDetails?.headline ?? state.value?.row?.headline ?? "",
                                 initialToss: finalCutDetails?.toss ?? state.value?.row?.toss ?? "") { details in
                finalCutDetails = details
                askFinalCut = false
            }
        }
        .sheet(isPresented: $editToss) {
            FinalCutDetailsSheet(mode: .toss, initialHeadline: "", initialToss: state.value?.row?.toss ?? "",
                                 saving: savingToss) { details in
                Task { await saveToss(details.toss) }
            }
        }
        .alert("Upload this Final Cut?", isPresented: Binding(get: { pendingFinalCut != nil }, set: { if !$0 { pendingFinalCut = nil } })) {
            Button("Not yet", role: .cancel) { pendingFinalCut = nil }
            Button("Upload Final Cut") {
                guard let file = pendingFinalCut else { return }
                pendingFinalCut = nil
                Task { await upload([file]) }
            }
        } message: {
            Text("Headline: \"\(finalCutDetails?.headline ?? "")\". You cannot replace it later unless the first grade is below 75%.")
        }
    }

    private var api: WorkAPI { workAPI(client) }

    @ViewBuilder
    private func content(_ view: StageView, row: StageRow) -> some View {
        let media = view.media ?? []
        let status = StageGuide.status(stage, view: view)
        header(row, status: status)
        if stage == .finalCut, row.packageOfCycleAt != nil {
            PackageOfCycleBanner(rowId: row.id, api: api)
        }
        WhereItStandsCard(
            nextStep: StageGuide.nextStep(stage, status: status, hasFinalCut: row.finalCut),
            approvalSteps: stage == .initialCut ? StageGuide.approvalPath(row, hasMedia: !media.isEmpty) : nil,
            rule: view.canUpload ? StageGuide.uploadRule(stage, hasMedia: !media.isEmpty) : nil,
            warning: stage == .finalCut && view.canUpload ? StageGuide.finalCutRule(allowSecondFinalCut: view.allowSecondFinalCut == true) : nil
        )
        if view.canUpload {
            uploadSection(view, hasMedia: !media.isEmpty)
        } else if stage == .initialCut, !view.isProducer, row.approvalStage == "APPROVED", !row.finalCut {
            NavigationLink(value: Route.work(.studentStage(.finalCut))) {
                Label("Go to Final Cut", systemImage: "arrow.right")
            }
            .buttonStyle(.brandPrimary)
        }
        if let notice {
            Label(notice.0, systemImage: notice.1 ? "checkmark.circle" : "exclamationmark.circle")
                .font(.small).foregroundStyle(notice.1 ? Brand.green : Brand.danger)
        }
        mediaSection(view, media: media, row: row)
        if stage == .finalCut, row.headline?.isEmpty == false || !(row.toss ?? "").isEmpty || view.canEditToss == true {
            WhatAirsCard(headline: row.headline, toss: row.toss ?? "", canEdit: view.canEditToss == true) { editToss = true }
        }
        StageCommentsSection(rowId: row.id, stage: stage.rawValue, canPost: false, api: api, refreshKey: refreshKey)
    }

    private func header(_ row: StageRow, status: StageStatus?) -> some View {
        Nameplate(eyebrow: "Cycle \(row.cycleNumber) · \(stage.title)",
                  title: row.groupTopic.isEmpty ? "My package" : row.groupTopic,
                  subtitle: BrainstormGuide.metaLine(members: row.members, producer: row.assignedProducer)) {
            if let status {
                StatusTag(text: StageGuide.label(status, remainingExecutiveSignoffs: row.remainingExecutiveSignoffs), tone: status.tone)
            }
        }
    }

    @ViewBuilder
    private func uploadSection(_ view: StageView, hasMedia: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: StageGuide.uploadLabel(stage, hasMedia: hasMedia, allowSecondFinalCut: view.allowSecondFinalCut == true))
            if stage == .aRoll {
                Picker("Kind", selection: $rollKind) {
                    Text("A-roll").tag("a-roll")
                    Text("B-roll").tag("b-roll")
                }
                .pickerStyle(.segmented)
            }
            if stage == .finalCut, let details = finalCutDetails {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Headline", color: Brand.muted)
                    Text(details.headline).font(.bodyText)
                    Button("Edit headline and toss") { askFinalCut = true }
                        .font(.small).foregroundStyle(Brand.green).frame(minHeight: 44)
                }
                .card(padding: 12)
            }
            if stage == .finalCut && finalCutDetails == nil {
                Button("Add headline and toss") { askFinalCut = true }.buttonStyle(.brandPrimary)
            } else {
                HStack(spacing: 12) {
                    Button { showPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                        .buttonStyle(.brandPrimary)
                    Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                        .buttonStyle(.brandSecondary)
                }
                .disabled(uploader.isBusy)
            }
            UploadProgressCard(uploader: uploader)
        }
    }

    @ViewBuilder
    private func mediaSection(_ view: StageView, media: [StageMedia], row: StageRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: stage == .aRoll ? "Footage" : stage == .initialCut ? "Versions" : "Your Final Cut")
            if media.isEmpty {
                Text(StageGuide.emptyMediaTitle(stage)).font(.small).foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                switch stage {
                case .aRoll: clips(media)
                case .initialCut: versions(media)
                default: finalCut(media)
                }
            }
        }
    }

    /// A-roll first, then B-roll; a clip opens with its own notes.
    @ViewBuilder
    private func clips(_ media: [StageMedia]) -> some View {
        ForEach(["a-roll", "b-roll", ""], id: \.self) { kind in
            let group = media.filter { ($0.rollKind ?? "") == kind }
            if !group.isEmpty {
                Eyebrow("\(kind == "a-roll" ? "A-roll" : kind == "b-roll" ? "B-roll" : "Other clips") · \(group.count)", color: Brand.muted)
                ForEach(group) { clip in StudentMediaRow(media: clip) { openClip = clip } }
            }
        }
    }

    /// Newest version first with its timecoded review; older ones fold away.
    @ViewBuilder
    private func versions(_ media: [StageMedia]) -> some View {
        if let latest = media.first {
            StudentMediaRow(media: latest, result: StageGuide.cutResult(latest), current: true) { play(latest) }
            reviewButton(latest, bare: true)
            let older = Array(media.dropFirst())
            if !older.isEmpty {
                Button(showOlder ? "Hide older versions" : "Show older versions (\(older.count))") { showOlder.toggle() }
                    .font(.lexend(14, .medium)).foregroundStyle(Brand.green).frame(minHeight: 44)
                if showOlder {
                    ForEach(older) { item in
                        StudentMediaRow(media: item, result: StageGuide.cutResult(item)) { play(item) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func finalCut(_ media: [StageMedia]) -> some View {
        ForEach(media) { item in
            StudentMediaRow(media: item) { play(item) }
            reviewButton(item, bare: false)
        }
    }

    @ViewBuilder
    private func reviewButton(_ media: StageMedia, bare: Bool) -> some View {
        if let path = StageGuide.reviewPath(media, bare: bare) {
            Button { router.openPortal(path, title: "Review") } label: {
                Label("Open review (timecoded notes)", systemImage: "text.bubble")
            }
            .buttonStyle(.brandSecondary)
        }
    }

    private func play(_ media: StageMedia) {
        if media.playbackUrl != nil { playing = media }
    }

    // MARK: Loading and saving

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.stage(stage.rawValue, nil, nil))
            refreshKey += 1
        } catch PortalError.forbidden {
            state = .failed("\(stage.title) isn't available for this account.")
        } catch {
            if state.value == nil { state = .failed(Loadable<StageView>.message(for: error)) }
        }
    }

    private func saveToss(_ toss: String) async {
        guard let row = state.value?.row else { return }
        savingToss = true
        defer { savingToss = false }
        do {
            try await api.saveToss(row.id, toss)
            editToss = false
            notice = ("Toss saved.", true)
            await load()
        } catch {
            notice = (Loadable<Void>.message(for: error), false)
            editToss = false
        }
    }

    // MARK: Uploads

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var files: [StageUploadFile] = []
        for item in items {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                files.append(StageUploadFile(url: movie.url, name: movieName(movie.url, index: files.count)))
            }
        }
        if files.count < items.count { notice = ("Some videos couldn't be read from Photos.", false) }
        await start(files)
    }

    private func importFiles(_ urls: [URL]) async {
        var files: [StageUploadFile] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil {
                files.append(StageUploadFile(url: copy, name: url.lastPathComponent))
            } else {
                notice = ("Couldn't read \(url.lastPathComponent).", false)
            }
        }
        await start(files)
    }

    private func movieName(_ url: URL, index: Int) -> String {
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        return "\(stage.rawValue)-\(Int(Date().timeIntervalSince1970))\(index > 0 ? "-\(index + 1)" : "").\(ext)"
    }

    /// Checks sizes, asks the Final Cut confirm when it can't be replaced, then uploads.
    private func start(_ picked: [StageUploadFile]) async {
        guard !picked.isEmpty else { return }
        let files = picked.map { file in
            var checked = file
            if stage == .aRoll { checked.problem = PackageText.rollSizeError(kind: rollKind, bytes: file.bytes) }
            return checked
        }
        if stage == .finalCut && state.value?.allowSecondFinalCut != true {
            pendingFinalCut = files.first
            return
        }
        await upload(stage == .aRoll ? files : Array(files.prefix(1)))
    }

    private func upload(_ files: [StageUploadFile]) async {
        guard let row = state.value?.row else { return }
        notice = nil
        let firstVersion = ((state.value?.media ?? []).first?.versionNumber ?? 0) + 1
        let kind = rollKind
        let details = finalCutDetails
        let uploaded = await uploader.uploadBatch(files, api: api) { file, index in
            let title: String
            switch stage {
            case .initialCut: title = StageGuide.cutTitle(version: firstVersion + index)
            case .finalCut: title = details?.headline ?? row.groupTopic
            default: title = (file.name as NSString).deletingPathExtension
            }
            return StageUploadRequest(rowId: row.id, stage: stage, title: String((title.isEmpty ? stage.title : title).prefix(150)),
                                      fileName: String(file.name.prefix(255)),
                                      rollKind: stage == .aRoll ? kind : nil,
                                      toss: stage == .finalCut ? details?.toss : nil)
        }
        if uploaded > 0 {
            if stage == .finalCut { finalCutDetails = nil }
            await load()
        }
    }
}
