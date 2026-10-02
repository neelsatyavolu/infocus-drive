import PhotosUI
import SwiftUI

/// A student's A-roll/B-roll, Initial Cut or Final Cut: status, what's uploaded,
/// uploading from Photos or Files, playback, and the producer's feedback.
struct StudentStageScreen: View {
    let stage: StudentStage

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var state: Loadable<StageView> = .idle
    @State private var uploader = StageUploader()
    @State private var playing: StageMedia?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showFiles = false
    @State private var rollKind = "a-roll"
    @State private var finalCutDetails: FinalCutDetails?
    @State private var askFinalCut = false

    var body: some View {
        ScrollView {
            LoadableView(state, retry: { Task { await load() } }) { view in
                VStack(alignment: .leading, spacing: 20) {
                    if view.empty || view.row == nil {
                        EmptyStateView(title: "Not on a package yet", message: "This stage opens when your group is on the roster.").card()
                    } else if view.unlocked == false {
                        EmptyStateView(title: "\(stage.title) is locked", message: "It opens after the stage before it is approved.").card()
                    } else if let row = view.row {
                        header(row)
                        uploadSection(view, row: row)
                        mediaSection(view)
                        StageCommentsSection(rowId: row.id, stage: stage.rawValue, canPost: false, api: api)
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await load() }
        .brandBackground()
        .navigationTitle(stage.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { router.openPortal(stage.rawValue, title: stage.title) } label: {
                    Image(systemName: "safari")
                }
                .accessibilityLabel("Open on the Portal")
            }
        }
        .task { if state.value == nil { await load() } }
        .fullScreenCover(item: $playing) { StagePlayerScreen(media: $0) }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) { await upload(movie.url) }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video, .audiovisualContent]) { result in
            guard case .success(let url) = result else { return }
            Task { await uploadFromFiles(url) }
        }
        .sheet(isPresented: $askFinalCut) {
            FinalCutDetailsSheet(initialToss: state.value?.row?.toss ?? "") { details in
                finalCutDetails = details
                askFinalCut = false
            }
        }
    }

    private var api: WorkAPI { workAPI(client) }

    private func header(_ row: StageRow) -> some View {
        Nameplate(eyebrow: "Cycle \(row.cycleNumber) · \(stage.title)", title: row.groupTopic, subtitle: row.memberNames) {
            if let status = statusTag(row) { StatusTag(text: status.0, tone: status.1) }
        }
    }

    private func statusTag(_ row: StageRow) -> (String, StatusTag.Tone)? {
        switch stage {
        case .aRoll:
            if row.aRollBRoll { return ("Approved", .success) }
            return row.aRollNeedsChanges ? ("Revisions", .danger) : nil
        case .initialCut:
            if row.approvalStage == "APPROVED" { return ("Approved", .success) }
            if row.initialCutNeedsRevisions { return ("Revisions", .danger) }
            switch row.approvalStage {
            case "ASSOCIATE_REVIEW": return ("Stage 1", .warning)
            case "ADVISER_REVIEW": return ("Stage 2", .warning)
            case "EXECUTIVE_REVIEW": return ("Stage 3", .warning)
            default: return nil
            }
        case .finalCut:
            if row.queuedForAirAt != nil { return ("Queued", .success) }
            return row.finalCut ? ("Submitted", .warning) : nil
        default:
            return nil
        }
    }

    @ViewBuilder
    private func uploadSection(_ view: StageView, row: StageRow) -> some View {
        if view.canUpload {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Upload")
                Text(uploadHint).font(.small).foregroundStyle(Brand.secondary)
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
                        Button("Edit headline and toss") { askFinalCut = true }.font(.small).foregroundStyle(Brand.green)
                    }
                    .card(padding: 12)
                }
                if stage == .finalCut && finalCutDetails == nil {
                    Button("Add headline and toss") { askFinalCut = true }.buttonStyle(.brandPrimary)
                } else {
                    HStack(spacing: 12) {
                        PhotosPicker(selection: $pickedPhoto, matching: .videos) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.brandPrimary)
                        Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                            .buttonStyle(.brandSecondary)
                    }
                    .disabled(uploader.isBusy)
                }
                UploadProgressCard(uploader: uploader)
            }
        }
    }

    private var uploadHint: String {
        switch stage {
        case .aRoll: "Upload your interviews (A-roll) and footage (B-roll). A-roll up to 30 GB, B-roll up to 15 GB."
        case .initialCut: "Upload your cut. It goes to your producer for Stage 1 review."
        case .finalCut: "Upload your finished package with its headline and a toss for the anchors."
        default: ""
        }
    }

    @ViewBuilder
    private func mediaSection(_ view: StageView) -> some View {
        let media = view.media ?? []
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: stage == .aRoll ? "Footage" : "Uploads")
            if media.isEmpty {
                Text("Nothing uploaded yet.").font(.small).foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                ForEach(media) { item in StageMediaCard(media: item) { playing = item } }
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.stage(stage.rawValue, nil, nil))
        } catch {
            if state.value == nil { state = .failed(Loadable<StageView>.message(for: error)) }
        }
    }

    private func uploadFromFiles(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            await upload(copy, name: url.lastPathComponent)
        } catch {
            await upload(url, name: url.lastPathComponent)
        }
    }

    private func upload(_ file: URL, name: String? = nil) async {
        guard let row = state.value?.row else { return }
        let fileName = name ?? "\(stage.rawValue)-\(Int(Date().timeIntervalSince1970)).\(file.pathExtension.isEmpty ? "mov" : file.pathExtension)"
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if stage == .aRoll, let error = PackageText.rollSizeError(kind: rollKind, bytes: size) {
            return uploader.fail(error)
        }
        let nextVersion = ((state.value?.media ?? []).first?.versionNumber ?? 0) + 1
        let title: String
        switch stage {
        case .initialCut: title = "Initial Cut Version \(nextVersion)"
        case .finalCut: title = finalCutDetails?.headline ?? row.groupTopic
        default: title = (fileName as NSString).deletingPathExtension
        }
        let request = StageUploadRequest(rowId: row.id, stage: stage, title: String(title.prefix(150)), fileName: fileName,
                                         rollKind: stage == .aRoll ? rollKind : nil,
                                         toss: stage == .finalCut ? finalCutDetails?.toss : nil)
        if await uploader.upload(file, request: request, api: api) {
            await load()
        }
    }
}

/// Final Cut: the package headline and the anchors' toss, asked before the upload.
struct FinalCutDetails: Equatable { let headline: String; let toss: String }

private struct FinalCutDetailsSheet: View {
    let initialToss: String
    let done: (FinalCutDetails) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var headline = ""
    @State private var toss = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Headline", text: $headline, axis: .vertical).font(.bodyText)
                } header: { Text("Headline") } footer: {
                    Text(PackageText.headlineError(headline) ?? "\(headline.count)/\(PackageText.headlineMax)")
                }
                Section {
                    TextField("What the anchor says before your package", text: $toss, axis: .vertical)
                        .font(.bodyText).lineLimit(3...8)
                } header: { Text("Toss for the anchors") } footer: {
                    Text(PackageText.tossError(toss) ?? "\(toss.count)/\(PackageText.tossMax)")
                }
            }
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Final Cut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        done(FinalCutDetails(headline: headline.trimmingCharacters(in: .whitespacesAndNewlines),
                                             toss: toss.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    .disabled(PackageText.headlineError(headline) != nil || PackageText.tossError(toss) != nil)
                }
            }
            .onAppear { if toss.isEmpty { toss = initialToss } }
        }
    }
}
