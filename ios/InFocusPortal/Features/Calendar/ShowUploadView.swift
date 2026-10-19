import PhotosUI
import SwiftUI

/// Upload show (producers), like the Portal's The Show dialog: pick the show's video, it goes to
/// InFocus Drive, review the title, description, when it goes public, the season playlist and the
/// thumbnail, then schedule it on YouTube. A show already sent shows its YouTube status.
struct ShowUploadView: View {
    let date: String

    @Environment(\.portalClient) private var client
    @State private var model: ShowUploadModel?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showFiles = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Nameplate(eyebrow: "Upload show", title: CalendarDates.long(date), subtitle: subtitle)
                if let model { content(model) } else { SkeletonList(rows: 3) }
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle("Upload show")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model?.isUploading == true)
        .scrollDismissesKeyboard(.interactively)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video, .audiovisualContent]) { result in
            if case .success(let url) = result { Task { await uploadFromFiles(url) } }
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task {
                guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
                    model?.error = "Couldn't read that video."
                    return
                }
                await model?.upload(movie.url, fileName: "show-\(date).\(movie.url.pathExtension)")
            }
        }
        .task {
            if model == nil { model = ShowUploadModel(date: date, api: .current(client)) }
            await model?.load()
        }
        .task(id: model?.phase == .status) { await model?.follow() }
        .onDisappear { if model?.isUploading == false { model?.removeFile() } }
    }

    private var subtitle: String? {
        guard let status = model?.state?.publication?.status, model?.phase == .status else { return nil }
        return "YouTube: " + ShowUploadRules.statusLabel(status)
    }

    @ViewBuilder
    private func content(_ model: ShowUploadModel) -> some View {
        if let error = model.error { EditErrorBanner(message: error) }
        switch model.phase {
        case .loading:
            SkeletonList(rows: 3)
        case .failed(let message):
            EmptyStateView(title: "Not available", message: message, actionTitle: "Try again") {
                Task { await model.load() }
            }
        case .pick:
            pick(model)
        case .uploading(let fraction):
            uploading(model, fraction: fraction)
        case .review:
            review(model)
        case .status:
            if let publication = model.state?.publication { status(publication) }
        }
    }

    // MARK: Pick

    private func pick(_ model: ShowUploadModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick the finished show. It uploads to InFocus Drive first, then you check the YouTube details.")
                .font(.bodyText)
                .foregroundStyle(Brand.secondary)
            if model.state?.configured == false {
                Label("YouTube publishing isn't set up on the Portal.", systemImage: "info.circle")
                    .font(.small).foregroundStyle(Brand.warning)
            }
            HStack(spacing: 12) {
                PhotosPicker(selection: $pickedPhoto, matching: .videos) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.brandPrimary)
                Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                    .buttonStyle(.brandSecondary)
            }
        }
        .card()
    }

    private func uploadFromFiles(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            await model?.upload(copy, fileName: url.lastPathComponent)
        } catch {
            model?.error = "Couldn't read that file."
        }
    }

    // MARK: Uploading

    private func uploading(_ model: ShowUploadModel, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: fraction) {
                Text("Uploading to InFocus Drive").font(.small)
            } currentValueLabel: {
                Text("\(Int(fraction * 100))%").font(.mono(12)).monospacedDigit()
            }
            .tint(Brand.green)
            Text("Keep InFocus open until it finishes.").font(.small).foregroundStyle(Brand.muted)
            thumbnailPreview(model)
        }
        .card()
    }

    // MARK: Review

    @ViewBuilder
    private func review(_ model: ShowUploadModel) -> some View {
        @Bindable var model = model
        if let form = Binding($model.form) {
            VStack(alignment: .leading, spacing: 14) {
                field("Title") {
                    TextField("Title", text: form.title)
                        .textInputAutocapitalization(.words)
                }
                field("Goes public (Pacific)") {
                    DatePicker("Goes public", selection: Binding(
                        get: { form.wrappedValue.publishAt ?? Date() },
                        set: { form.wrappedValue.setPublishAt($0) }
                    ))
                    .labelsHidden()
                    .environment(\.timeZone, ShowUploadRules.timeZone)
                }
                field("Playlist season", hint: model.seasonHint) {
                    TextField("Season", text: form.seasonNumber)
                        .keyboardType(.numberPad)
                        .font(.mono(16))
                }
                field("Description") {
                    TextEditor(text: form.description)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Thumbnail", color: Brand.muted)
                thumbnailPreview(model)
                HStack(spacing: 8) {
                    TextField("Seconds", text: $model.thumbnailSeconds)
                        .keyboardType(.decimalPad)
                        .font(.mono(16))
                        .padding(.horizontal, 12)
                        .frame(width: 110, height: 44)
                        .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
                        .accessibilityLabel("Thumbnail time in seconds")
                    Button("Grab frame") { Task { await model.retake() } }
                        .buttonStyle(.brandSecondary)
                        .disabled(model.capturing)
                }
            }
            .card()

            VStack(spacing: 10) {
                Button {
                    Task { await model.schedule() }
                } label: {
                    if model.submitting { ProgressView() } else { Text("Schedule on YouTube") }
                }
                .buttonStyle(.brandPrimary)
                .disabled(model.submitting || model.capturing || form.wrappedValue.title.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Choose a different file") { model.chooseAnotherFile() }
                    .buttonStyle(.brandQuiet)
                    .disabled(model.submitting)
            }
        }
    }

    private func field(_ label: String, hint: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.small).foregroundStyle(Brand.muted)
            content()
                .font(.bodyText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
            if let hint { Text(hint).font(.small).foregroundStyle(Brand.secondary) }
        }
    }

    private func thumbnailPreview(_ model: ShowUploadModel) -> some View {
        ZStack {
            Brand.raised
            if let data = model.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if model.capturing {
                ProgressView()
            } else {
                Text("No thumbnail yet. YouTube picks one if you skip it.")
                    .font(.small).foregroundStyle(Brand.muted).multilineTextAlignment(.center).padding()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
        .accessibilityLabel(model.thumbnail == nil ? "No thumbnail" : "Thumbnail preview")
    }

    // MARK: Status

    private func status(_ publication: ShowUploadState.Publication) -> some View {
        let active = ShowUploadRules.active.contains(publication.status)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusTag(text: ShowUploadRules.statusLabel(publication.status),
                          tone: publication.status == "FAILED" ? .danger : publication.status == "SCHEDULED" ? .success : .neutral)
                if active { ProgressView().controlSize(.small) }
            }
            if let detail = ShowUploadRules.statusDetail(publication.status) {
                Text(detail).font(.small).foregroundStyle(Brand.secondary)
            }
            if publication.status == "UPLOADING",
               let percent = ShowUploadRules.percent(uploaded: publication.uploadedBytes, total: publication.totalBytes) {
                ProgressView(value: Double(percent), total: 100) {
                    Text("Upload to YouTube").font(.small)
                } currentValueLabel: {
                    Text("\(percent)%").font(.mono(12)).monospacedDigit()
                }
                .tint(Brand.green)
            }
            Text(publication.title).font(.lexend(17, .semibold, relativeTo: .headline))
            Text("Goes public " + publication.publishAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
                                                                                    timeZone: ShowUploadRules.timeZone)) + " Pacific"
                 + (publication.seasonNumber.map { " · InFocus News | Season \($0)" } ?? ""))
                .font(.small)
                .foregroundStyle(Brand.secondary)
            if let error = publication.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").font(.small).foregroundStyle(Brand.danger)
            }
            if let watch = publication.watchUrl {
                Link(destination: watch) { Label("Open on YouTube", systemImage: "play.rectangle") }
                    .buttonStyle(.brandSecondary)
            }
            Text("To change it now, use YouTube Studio.").font(.small).foregroundStyle(Brand.muted)
        }
        .card()
    }
}
