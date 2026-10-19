import SwiftUI

/// Final Cut: the package headline and the anchors' toss, asked before the upload.
struct FinalCutDetails: Equatable { let headline: String; let toss: String }

/// Upload mode asks for the headline and toss before the video is picked; toss
/// mode edits only the toss of a Final Cut that's already up (the website's
/// `FinalCutHeadlineDialog`).
struct FinalCutDetailsSheet: View {
    enum Mode { case upload, toss }

    var mode: Mode = .upload
    let initialHeadline: String
    let initialToss: String
    var saving = false
    let done: (FinalCutDetails) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var headline = ""
    @State private var toss = ""
    @State private var filled = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(mode == .upload
                         ? "The headline becomes the package title in the Publishing Queue and on YouTube. The toss is what an anchor reads right before your package airs."
                         : "What an anchor reads right before your package airs. It fills in the show's teleprompter script.")
                        .font(.small)
                        .foregroundStyle(Brand.secondary)
                        .listRowBackground(Color.clear)
                }
                if mode == .upload {
                    Section {
                        TextField("Headline", text: $headline, axis: .vertical).font(.bodyText)
                    } header: { Text("Headline") } footer: {
                        Text(PackageText.headlineError(headline) ?? "\(headline.trimmingCharacters(in: .whitespacesAndNewlines).count)/\(PackageText.headlineMax)")
                    }
                }
                Section {
                    TextField("What the anchor says before your package", text: $toss, axis: .vertical)
                        .font(.bodyText).lineLimit(3...8)
                } header: { Text("Toss for the anchors") } footer: {
                    Text(PackageText.tossError(toss) ?? "\(toss.trimmingCharacters(in: .whitespacesAndNewlines).count)/\(PackageText.tossMax)")
                }
            }
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle(mode == .upload ? "Headline and toss" : "Toss for the anchors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : mode == .upload ? "Continue" : "Save") {
                        done(FinalCutDetails(headline: headline.trimmingCharacters(in: .whitespacesAndNewlines),
                                             toss: toss.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    .disabled(saving || !isValid)
                }
            }
            .onAppear {
                guard !filled else { return }
                filled = true
                headline = initialHeadline
                toss = initialToss
            }
        }
    }

    private var isValid: Bool {
        (mode == .toss || PackageText.headlineError(headline) == nil) && PackageText.tossError(toss) == nil
    }
}

/// "What airs": the Final Cut's headline and the anchors' toss, with Edit toss.
struct WhatAirsCard: View {
    let headline: String?
    let toss: String
    let canEdit: Bool
    let onEdit: () -> Void

    var body: some View {
        let missingToss = toss.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "What airs")
                if missingToss { StatusTag(text: "No toss", tone: .warning) }
            }
            if let headline, !headline.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Headline", color: Brand.muted)
                    Text(headline).font(.lexend(16, .medium)).foregroundStyle(Brand.foreground)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Toss", color: Brand.muted)
                Text(missingToss ? "No toss yet. The anchors read it right before this package airs." : toss)
                    .font(.bodyText)
                    .foregroundStyle(missingToss ? Brand.muted : Brand.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canEdit {
                Button(action: onEdit) {
                    Label(missingToss ? "Add a toss" : "Edit toss", systemImage: "pencil")
                }
                .buttonStyle(.brandSecondary)
            }
        }
        .card()
    }
}

/// Package of the Cycle: the executive producers picked this package. Members
/// can save their certificate (a PNG from the Portal).
struct PackageOfCycleBanner: View {
    let rowId: String
    let api: WorkAPI
    @State private var file: URL?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Package of the Cycle", systemImage: "rosette")
                .font(.h3)
                .foregroundStyle(Brand.green)
            Text("The executive producers chose your package as one of the best this cycle.")
                .font(.bodyText)
                .foregroundStyle(Brand.secondary)
            if let file {
                ShareLink(item: file) { Label("Save or share certificate", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.brandPrimary)
            } else {
                Button { Task { await download() } } label: {
                    Label(loading ? "Getting certificate…" : "Get certificate", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.brandSecondary)
                .disabled(loading)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
            }
        }
        .card()
    }

    private func download() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let data = try await api.certificate(rowId)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Package of the Cycle certificate.png")
            try data.write(to: url, options: .atomic)
            file = url
        } catch {
            self.error = Loadable<Void>.message(for: error)
        }
    }
}
