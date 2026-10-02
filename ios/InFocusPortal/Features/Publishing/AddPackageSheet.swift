import PhotosUI
import SwiftUI

/// Add to the queue: a final cut that isn't queued yet, or a custom video.
/// Either lands on the next empty show (automatic placement never stacks).
struct AddPackageSheet: View {
    let model: PublishingModel
    let service: PublishingService
    @Environment(\.dismiss) private var dismiss
    @State private var uploader = CustomPackageUploader()
    @State private var title = ""
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showFiles = false

    var body: some View {
        NavigationStack {
            List {
                customSection
                candidatesSection
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Add to the queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .interactiveDismissDisabled(uploader.isBusy)
            .publishingAlerts(model)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video, .audiovisualContent]) { result in
                if case .success(let url) = result { Task { await uploadFromFiles(url) } }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                Task {
                    if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                        await upload(movie.url, fileName: "custom-\(Int(Date().timeIntervalSince1970)).\(movie.url.pathExtension)")
                    } else {
                        uploader.reset()
                    }
                }
            }
            .task { await model.load(service, candidates: true) }
        }
    }

    private var customSection: some View {
        Section {
            TextField("Title", text: $title)
                .textInputAutocapitalization(.sentences)
                .disabled(uploader.isBusy)
            switch uploader.phase {
            case .uploading(let fraction):
                ProgressView(value: fraction) {
                    Text("Uploading to InFocus Drive").font(.small)
                } currentValueLabel: {
                    Text("\(Int(fraction * 100))%").font(.mono(12)).monospacedDigit()
                }
                .tint(Brand.green)
            case .finishing:
                HStack { ProgressView(); Text("Adding to the queue…").font(.small) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.small).foregroundStyle(Brand.danger)
            case .idle:
                EmptyView()
            }
            HStack(spacing: 12) {
                PhotosPicker(selection: $pickedPhoto, matching: .videos) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.brandSecondary)
                Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                    .buttonStyle(.brandSecondary)
            }
            .disabled(uploader.isBusy || CustomPackageUploader.cleanTitle(title) == nil)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("Custom package")
        } footer: {
            Text("Give it a title, then pick the video. Keep InFocus open until it finishes.").font(.small)
        }
    }

    private var candidatesSection: some View {
        Section {
            let candidates = model.payload?.candidates ?? []
            if candidates.isEmpty {
                Text("No other final cuts are ready to add.").foregroundStyle(Brand.secondary)
            }
            ForEach(candidates) { candidate in
                Button {
                    Task { await model.add(candidate, service: service) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.groupTopic.isEmpty ? "Untitled group" : candidate.groupTopic)
                                .foregroundStyle(Brand.foreground)
                            Text(QueueLogic.subtitle(custom: candidate.custom ?? false, cycleNumber: candidate.cycleNumber,
                                                     members: candidate.members))
                                .font(.small)
                                .foregroundStyle(Brand.muted)
                        }
                        Spacer()
                        if model.busyRowId == candidate.id {
                            ProgressView()
                        } else {
                            Image(systemName: "plus.circle").foregroundStyle(Brand.green)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(model.busyRowId != nil || uploader.isBusy)
                .accessibilityHint("Adds it to the next empty show")
            }
        } header: {
            Text("Final cuts ready")
        }
    }

    private func uploadFromFiles(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            await upload(copy, fileName: url.lastPathComponent)
        } catch {
            uploader.reset()
            model.actionError = "Couldn't read that file."
        }
    }

    private func upload(_ file: URL, fileName: String) async {
        if await uploader.upload(file, fileName: fileName, title: title, service: service) {
            title = ""
            await model.added(service: service)
            dismiss()
        }
    }
}
