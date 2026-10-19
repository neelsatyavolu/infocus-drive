import PhotosUI
import SwiftUI

/// Brainstorming: three proofs of contact (screenshots of messages with sources)
/// and the group's Google Doc link. Once both are in, the package waits for the
/// producer's approval. Like the website: a cycle picker, tabs when the viewer is
/// on several packages, removing a proof, and the producer's feedback.
struct BrainstormScreen: View {
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<BrainstormPayload> = .idle
    @State private var currentCycle: Int?
    @State private var chosenCycle: Int?
    @State private var chosenId: String?
    @State private var docDrafts: [String: String] = [:]
    @State private var savingDoc = false
    @State private var message: (String, Bool)?
    @State private var pickingSlot: Int?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var uploadingSlot: Int?
    @State private var viewing: ProofView?
    @State private var removing: Int?
    @State private var refreshKey = 0

    var body: some View {
        ScrollView {
            LoadableView(state, retry: { Task { await load() } }) { payload in
                VStack(alignment: .leading, spacing: 20) {
                    controls(payload)
                    if let package = active(payload) {
                        workspace(package)
                    } else {
                        Nameplate(eyebrow: "Cycle \(payload.activeCycleNumber)", title: "Brainstorming",
                                  subtitle: BrainstormGuide.instructions)
                        EmptyStateView(title: "You are not on a package group for this cycle yet.",
                                       message: "Once a producer adds you on Package Cycle, this page will open for that package.").card()
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { docDrafts = [:]; await load() }
        .brandBackground()
        .navigationTitle("Brainstorming")
        .navigationBarTitleDisplayMode(.inline)
        .task { if state.value == nil { await load() } }
        .photosPicker(isPresented: Binding(get: { pickingSlot != nil }, set: { if !$0 && pickedPhoto == nil { pickingSlot = nil } }),
                      selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item, let slot = pickingSlot, let payload = state.value, let package = active(payload) else { return }
            pickedPhoto = nil
            pickingSlot = nil
            Task { await uploadProof(item, slot: slot, rowId: package.id) }
        }
        .fullScreenCover(item: $viewing) { proof in ProofViewer(proof: proof, api: api) }
        .confirmationDialog("Remove proof \(removing ?? 0)?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let slot = removing, let payload = state.value, let package = active(payload) else { return }
                removing = nil
                Task { await removeProof(slot, rowId: package.id) }
            }
        } message: {
            Text("The image is deleted. You can upload a new one afterward.")
        }
    }

    private var api: WorkAPI { workAPI(client) }

    private func active(_ payload: BrainstormPayload) -> BrainstormPackage? {
        payload.packages.first { $0.id == chosenId } ?? payload.packages.first
    }

    @ViewBuilder
    private func controls(_ payload: BrainstormPayload) -> some View {
        let cycles = payload.cycles ?? []
        if cycles.count > 1 {
            Menu {
                ForEach(cycles, id: \.cycleNumber) { cycle in
                    Button {
                        Task { await switchCycle(cycle.cycleNumber) }
                    } label: {
                        let focus = cycle.focus?.trimmingCharacters(in: .whitespaces) ?? ""
                        Text("Cycle \(cycle.cycleNumber)\(focus.isEmpty ? "" : " · \(focus)")\(cycle.cycleNumber == currentCycle ? " (current)" : "")")
                    }
                }
            } label: {
                Label("Cycle \(payload.activeCycleNumber)", systemImage: "chevron.up.chevron.down")
                    .font(.lexend(15, .medium))
            }
            .buttonStyle(.brandSecondary)
            .accessibilityLabel("Cycle \(payload.activeCycleNumber). Change cycle")
        }
        if payload.packages.count > 1 {
            Picker("Package", selection: Binding(get: { active(payload)?.id ?? "" }, set: { chosenId = $0 })) {
                ForEach(payload.packages) { package in
                    Text(package.groupTopic.isEmpty ? "Untitled package" : package.groupTopic).tag(package.id)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func workspace(_ package: BrainstormPackage) -> some View {
        let status = BrainstormGuide.status(package)
        Nameplate(eyebrow: "Cycle \(package.cycleNumber) · Brainstorming",
                  title: package.groupTopic.isEmpty ? "Untitled package" : package.groupTopic,
                  subtitle: BrainstormGuide.metaLine(members: package.members, producer: package.assignedProducer)) {
            StatusTag(text: status.label, tone: status.tone)
        }
        VStack(alignment: .leading, spacing: 12) {
            WhereItStandsCard(nextStep: BrainstormGuide.nextStep(package))
            if package.proofOfContact && package.cycleNumber == currentCycle {
                NavigationLink(value: Route.work(.studentStage(.aRoll))) {
                    Label("Open A-roll/B-roll", systemImage: "arrow.right")
                }
                .buttonStyle(.brandPrimary)
            }
        }
        if status != .approved {
            Text(BrainstormGuide.instructions).font(.small).foregroundStyle(Brand.secondary)
        }
        proofsSection(package)
        docSection(package)
        if let message {
            Label(message.0, systemImage: message.1 ? "checkmark.circle" : "exclamationmark.circle")
                .font(.small).foregroundStyle(message.1 ? Brand.green : Brand.danger)
        }
        StageCommentsSection(rowId: package.id, stage: "brainstorming", canPost: false, api: api,
                             refreshKey: refreshKey)
    }

    private func canEdit(_ package: BrainstormPackage) -> Bool { package.canEdit ?? true }

    private func docSection(_ package: BrainstormPackage) -> some View {
        let saved = package.brainstormDocUrl ?? ""
        let draft = docDrafts[package.id] ?? saved
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = trimmed.isEmpty || GoogleDocLink.isValid(trimmed)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Brainstorm doc")
            TextField("https://docs.google.com/…", text: Binding(get: { draft }, set: { docDrafts[package.id] = $0 }))
                .font(.bodyText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(valid ? Brand.control : Brand.danger))
                .disabled(!canEdit(package))
            if !valid {
                Text("Paste a Google Docs or Drive link.").font(.small).foregroundStyle(Brand.danger)
            }
            HStack(spacing: 12) {
                if let url = URL(string: saved), GoogleDocLink.isValid(saved) {
                    Link(destination: url) { Label("Open doc", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.brandSecondary)
                }
                if canEdit(package) {
                    Button(savingDoc ? "Saving…" : trimmed.isEmpty && !saved.isEmpty ? "Remove link" : "Save link") {
                        Task { await saveDoc(package, url: trimmed) }
                    }
                    .buttonStyle(.brandPrimary)
                    .disabled(savingDoc || !valid || trimmed == saved.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    private func proofsSection(_ package: BrainstormPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Proofs of contact")
                Text("\(package.proofs.count) of \(BrainstormPackage.proofSlots.count)")
                    .font(.mono(13)).foregroundStyle(Brand.muted)
            }
            Text("Screenshots of your messages with three sources.").font(.small).foregroundStyle(Brand.secondary)
            HStack(spacing: 10) {
                ForEach(BrainstormPackage.proofSlots, id: \.self) { slot in
                    ProofSlotView(slot: slot, proof: package.proof(in: slot), canEdit: canEdit(package),
                                  uploading: uploadingSlot == slot, busy: uploadingSlot != nil, api: api,
                                  onPick: { pickingSlot = slot },
                                  onView: { viewing = package.proof(in: slot) },
                                  onRemove: { removing = slot })
                }
            }
        }
    }

    // MARK: Loading and saving

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let payload = try await api.brainstorm(chosenCycle)
            if currentCycle == nil && chosenCycle == nil { currentCycle = payload.activeCycleNumber }
            state = .loaded(payload)
            refreshKey += 1
        } catch PortalError.forbidden {
            state = .failed("Brainstorming isn't available for this account.")
        } catch {
            if state.value == nil { state = .failed(Loadable<BrainstormPayload>.message(for: error)) }
        }
    }

    private func switchCycle(_ cycle: Int) async {
        chosenCycle = cycle == currentCycle ? nil : cycle
        docDrafts = [:]
        message = nil
        state = .loading
        await load()
    }

    private func saveDoc(_ package: BrainstormPackage, url: String) async {
        savingDoc = true
        defer { savingDoc = false }
        do {
            try await api.saveDocLink(package.id, url)
            docDrafts[package.id] = nil
            message = (url.isEmpty ? "Link removed." : "Google Doc saved.", true)
            await load()
        } catch {
            message = (Loadable<Void>.message(for: error), false)
        }
    }

    private func uploadProof(_ item: PhotosPickerItem, slot: Int, rowId: String) async {
        uploadingSlot = slot
        defer { uploadingSlot = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
              let jpeg = ProofUpload.jpeg(from: image) else {
            message = ("Couldn't read that image. Try another.", false)
            return
        }
        do {
            try await api.uploadProof(rowId, slot, jpeg)
            message = ("Proof \(slot) uploaded.", true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } catch {
            message = (Loadable<Void>.message(for: error), false)
        }
    }

    private func removeProof(_ slot: Int, rowId: String) async {
        do {
            try await api.removeProof(rowId, slot)
            message = ("Proof removed.", true)
            await load()
        } catch {
            message = (Loadable<Void>.message(for: error), false)
        }
    }
}

/// One proof-of-contact slot: the image (tap to view), or an Add button.
private struct ProofSlotView: View {
    let slot: Int
    let proof: ProofView?
    let canEdit: Bool
    let uploading: Bool
    let busy: Bool
    let api: WorkAPI
    let onPick: () -> Void
    let onView: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button { proof == nil ? onPick() : onView() } label: {
                ZStack {
                    if let proof {
                        PortalImage(path: proof.imageUrl, api: api)
                    } else {
                        Brand.raised
                        VStack(spacing: 4) {
                            Image(systemName: canEdit ? "plus" : "photo").font(.system(size: 20))
                            Text(canEdit ? "Proof \(slot)" : "No proof yet").font(.small)
                        }
                        .foregroundStyle(Brand.muted)
                    }
                    if uploading { Color.black.opacity(0.4); ProgressView().tint(.white) }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
            }
            .buttonStyle(.plain)
            .disabled(proof == nil && (!canEdit || busy))
            .accessibilityLabel(proof == nil ? "Add proof \(slot)" : "View proof \(slot)")
            if proof != nil && canEdit {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "xmark").font(.small)
                }
                .buttonStyle(QuietDestructiveButtonStyle())
                .disabled(busy)
                .accessibilityLabel("Remove proof \(slot)")
            } else {
                Text("Proof \(slot)").font(.small).foregroundStyle(Brand.muted).frame(minHeight: 44)
            }
        }
    }
}

/// A proof of contact, full screen.
private struct ProofViewer: View {
    let proof: ProofView
    let api: WorkAPI
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                PortalImage(path: proof.imageUrl, api: api, fit: true)
            }
            .navigationTitle(proof.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
