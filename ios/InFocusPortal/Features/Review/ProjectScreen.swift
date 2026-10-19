import PhotosUI
import SwiftUI

/// A project: folders, its videos and images (filter, sort, deleted items), uploads,
/// folders and guest links. Tapping an item opens the review.
struct ProjectScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.portalClient) private var client
    @State private var model: ProjectModel
    @State private var uploader = MediaUploader()
    @State private var pickVideo = false
    @State private var pickPhoto = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var newFolder: String?
    @State private var renaming: ReviewMedia?
    @State private var renameText = ""
    @State private var airing: ReviewMedia?
    @State private var forever: ReviewMedia?

    init(projectId: String, folderId: String?) {
        _model = State(initialValue: ProjectModel(projectId: projectId, folderId: folderId))
    }

    private var api: ReviewAPI { .resolve(client) }
    private var canManage: Bool { ReviewLogic.canManageMedia(role: model.role, isProducer: session.user?.isProducer == true) }
    private var canChangeStatus: Bool { session.user?.isProducer == true }

    var body: some View {
        LoadableView(model.shell, retry: { Task { await model.load(api) } }) { shell in
            content(shell)
        }
        .brandBackground()
        .navigationTitle(model.shell.value?.projectName ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { if model.shell.value == nil { await model.load(api) } }
        .photosPicker(isPresented: $pickVideo, selection: $pickedItem, matching: .videos)
        .photosPicker(isPresented: $pickPhoto, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task { await upload(item) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video, .audiovisualContent]) { result in
            if case .success(let url) = result { Task { await uploadFile(url) } }
        }
        .modifier(ProjectDialogs(model: model, api: api, newFolder: $newFolder, renaming: $renaming, renameText: $renameText,
                                 airing: $airing, forever: $forever))
    }

    @ViewBuilder
    private func content(_ shell: ReviewProjectShell) -> some View {
        List {
            Section {
                Nameplate(eyebrow: shell.workspace.name, title: shell.projectName,
                          subtitle: "\(shell.assetCount) \(shell.assetCount == 1 ? "item" : "items")")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                FolderChips(folders: shell.folders, selected: model.query.folderId) { folderId in
                    model.query.folderId = folderId
                    Task { await model.reloadItems(api) }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                ProjectFilters(model: model, showDeleted: canManage) { Task { await model.reloadItems(api) } }
                    .listRowBackground(Color.clear)
                UploadStatusRow(uploader: uploader)
            }
            Section {
                if model.items.isEmpty && !model.loadingItems {
                    EmptyStateView(title: model.query.scope == .deleted ? "Nothing deleted" : "Nothing here yet",
                                   message: model.query.scope == .deleted ? "Deleted items show up here." : "Add a video or a photo with +.")
                        .listRowBackground(Color.clear)
                }
                ForEach(model.items) { item in
                    row(item)
                }
                if model.hasMore {
                    Button("Show more") { Task { await model.loadMore(api) } }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(Brand.green)
                } else if model.loadingItems {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .font(.bodyText)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(api) }
    }

    @ViewBuilder
    private func row(_ item: ReviewMedia) -> some View {
        let label = MediaRow(item: item, api: api, busy: model.busyId == item.id)
        Group {
            if item.isDeleted {
                label
            } else {
                NavigationLink(value: Route.review(.media(projectId: model.projectId, mediaId: item.id))) { label }
            }
        }
        .contextMenu { menu(item) }
        .swipeActions {
            if canManage {
                if item.isDeleted {
                    Button("Restore") { Task { await model.restore(item, api: api) } }.tint(Brand.fill)
                } else {
                    Button("Delete", role: .destructive) { Task { await model.delete(item, api: api) } }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(_ item: ReviewMedia) -> some View {
        if item.isDeleted {
            if canManage {
                Button { Task { await model.restore(item, api: api) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                Button(role: .destructive) { forever = item } label: { Label("Delete forever", systemImage: "trash") }
            }
        } else {
            if ReviewLogic.canRename(role: model.role) {
                Button {
                    renameText = item.title
                    renaming = item
                } label: { Label("Rename", systemImage: "pencil") }
            }
            if canChangeStatus, let version = item.currentVersion {
                Menu("Set status") {
                    ForEach(ReviewLogic.transitions(from: version.approvalStatus), id: \.self) { status in
                        Button(ReviewLogic.label(status)) {
                            if status == .aired { airing = item } else { Task { await model.setApproval(item, to: status, airedAt: nil, api: api) } }
                        }
                    }
                }
            }
            if canManage {
                Button(role: .destructive) { Task { await model.delete(item, api: api) } } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { pickVideo = true } label: { Label("Video from Photos", systemImage: "video") }
                Button { showFiles = true } label: { Label("Video from Files", systemImage: "folder") }
                Button { pickPhoto = true } label: { Label("Photo", systemImage: "photo") }
                Divider()
                Button { newFolder = "" } label: { Label("New folder", systemImage: "folder.badge.plus") }
                if let shell = model.shell.value, ReviewLogic.canShare(role: model.role, shell: shell) {
                    Button { router.push(.review(.shareLinks(projectId: model.projectId))) } label: {
                        Label("Share links", systemImage: "link")
                    }
                }
            } label: {
                Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(uploader.isBusy)
            .accessibilityLabel("Add")
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return uploader.reset() }
            if await uploader.uploadImage(data, projectId: model.projectId, folderId: model.query.folderId, api: api) {
                await model.load(api)
            }
        } else if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
            await uploadMovie(movie.url, fileName: "video-\(Int(Date().timeIntervalSince1970)).\(movie.url.pathExtension)")
        }
    }

    private func uploadFile(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            model.actionError = "That file couldn't be opened."
            return
        }
        await uploadMovie(copy, fileName: url.lastPathComponent)
    }

    private func uploadMovie(_ file: URL, fileName: String) async {
        if await uploader.uploadVideo(file, fileName: fileName, projectId: model.projectId, folderId: model.query.folderId, api: api) {
            await model.load(api)
        }
    }
}

/// Top level and each folder, as chips.
private struct FolderChips: View {
    let folders: [ReviewFolder]
    let selected: String?
    let select: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "Top level", selected: selected == nil) { select(nil) }
                ForEach(folders) { folder in
                    Chip(title: "\(folder.name) · \(folder.activeMediaCount)", selected: selected == folder.id) { select(folder.id) }
                }
            }
        }
    }
}

/// Filter, sort, and active or deleted items.
private struct ProjectFilters: View {
    @Bindable var model: ProjectModel
    let showDeleted: Bool
    let changed: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $model.query.filter) {
                Text("All").tag(ReviewMediaQuery.Filter.all)
                Text("Ready").tag(ReviewMediaQuery.Filter.ready)
                Text("In progress").tag(ReviewMediaQuery.Filter.inProgress)
                Text("Failed").tag(ReviewMediaQuery.Filter.failed)
            }
            Picker("Sort", selection: $model.query.sort) {
                Text("Recent").tag(ReviewMediaQuery.Sort.recent)
                Text("Name").tag(ReviewMediaQuery.Sort.name)
                Text("Status").tag(ReviewMediaQuery.Sort.status)
            }
            Spacer(minLength: 0)
            if showDeleted {
                Picker("Items", selection: $model.query.scope) {
                    Text("Active").tag(ReviewMediaQuery.Scope.active)
                    Text("Deleted").tag(ReviewMediaQuery.Scope.deleted)
                }
            }
        }
        .pickerStyle(.menu)
        .tint(Brand.green)
        .font(.small)
        .onChange(of: model.query.filter) { changed() }
        .onChange(of: model.query.sort) { changed() }
        .onChange(of: model.query.scope) { changed() }
    }
}

/// The upload in progress, or how the last one ended.
private struct UploadStatusRow: View {
    let uploader: MediaUploader

    var body: some View {
        switch uploader.phase {
        case .idle:
            EmptyView()
        case .preparing, .finishing:
            HStack(spacing: 12) {
                ProgressView()
                Text(uploader.phase == .preparing ? "Starting upload…" : "Finishing…").font(.small)
            }
        case .uploading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(uploader.fileName).font(.lexend(14, .medium)).lineLimit(1)
                    Spacer()
                    Text(fraction, format: .percent.precision(.fractionLength(0))).font(.mono(13, .medium)).monospacedDigit()
                }
                ProgressView(value: fraction).tint(Brand.fill)
                Text("Keep InFocus open until the upload finishes.").font(.small).foregroundStyle(Brand.muted)
            }
            .accessibilityElement(children: .combine)
        case .done:
            Label("Uploaded", systemImage: "checkmark.circle.fill").font(.small).foregroundStyle(Brand.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.small).foregroundStyle(Brand.danger)
        }
    }
}

/// The project's alerts and sheets: new folder, rename, aired date, delete forever, errors.
private struct ProjectDialogs: ViewModifier {
    let model: ProjectModel
    let api: ReviewAPI
    @Binding var newFolder: String?
    @Binding var renaming: ReviewMedia?
    @Binding var renameText: String
    @Binding var airing: ReviewMedia?
    @Binding var forever: ReviewMedia?

    func body(content: Content) -> some View {
        content
            .alert("New folder", isPresented: present($newFolder)) {
                TextField("Folder name", text: Binding(get: { newFolder ?? "" }, set: { newFolder = $0 }))
                Button("Cancel", role: .cancel) {}
                Button("Create") { let name = newFolder ?? ""; Task { await model.createFolder(name, api: api) } }
            }
            .alert("Rename", isPresented: present($renaming)) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let item = renaming { Task { await model.rename(item, to: renameText, api: api) } } }
            }
            .sheet(item: $airing) { item in
                AiredDateSheet { date in Task { await model.setApproval(item, to: .aired, airedAt: date, api: api) } }
            }
            .confirmationDialog("Delete forever?", isPresented: present($forever), titleVisibility: .visible, presenting: forever) { item in
                Button("Delete \(item.title) forever", role: .destructive) { Task { await model.deleteForever(item, api: api) } }
            } message: { _ in
                Text("Its versions and comments can't be brought back.")
            }
            .alert("Couldn't finish that", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
    }

    private func present<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}
