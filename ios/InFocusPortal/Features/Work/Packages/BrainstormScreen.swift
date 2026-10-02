import PhotosUI
import SwiftUI

/// Brainstorming: the group's Google Doc link and three proofs of contact
/// (screenshots of emails or texts with sources). Once both are in, the
/// package waits for the producer's approval.
struct BrainstormScreen: View {
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<BrainstormPayload> = .idle
    @State private var docLink = ""
    @State private var savingDoc = false
    @State private var message: (String, Bool)?
    @State private var pickingSlot: Int?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var uploadingSlot: Int?

    var body: some View {
        ScrollView {
            LoadableView(state, retry: { Task { await load() } }) { payload in
                VStack(alignment: .leading, spacing: 20) {
                    if let package = payload.packages.first {
                        Nameplate(eyebrow: "Cycle \(package.cycleNumber) · Brainstorming", title: package.groupTopic,
                                  subtitle: package.members.map(\.displayName).joined(separator: ", ")) {
                            StatusTag(text: package.proofOfContact ? "Approved" : ready(package) ? "Submitted" : "Pending",
                                      tone: package.proofOfContact ? .success : ready(package) ? .warning : .neutral)
                        }
                        docSection(package)
                        proofsSection(package)
                        if let message {
                            Label(message.0, systemImage: message.1 ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.small).foregroundStyle(message.1 ? Brand.green : Brand.danger)
                        }
                        StageCommentsSection(rowId: package.id, stage: "brainstorming", canPost: false, api: api)
                    } else {
                        EmptyStateView(title: "Not on a package yet",
                                       message: "When your group is on the Package Cycle roster, brainstorming opens here.").card()
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await load() }
        .brandBackground()
        .navigationTitle("Brainstorming")
        .navigationBarTitleDisplayMode(.inline)
        .task { if state.value == nil { await load() } }
        .photosPicker(isPresented: Binding(get: { pickingSlot != nil }, set: { if !$0 && pickedPhoto == nil { pickingSlot = nil } }),
                      selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item, let slot = pickingSlot, let package = state.value?.packages.first else { return }
            pickedPhoto = nil
            pickingSlot = nil
            Task { await uploadProof(item, slot: slot, rowId: package.id) }
        }
    }

    private var api: WorkAPI { workAPI(client) }

    private func ready(_ package: BrainstormPackage) -> Bool {
        package.proofs.count >= BrainstormPackage.proofSlots.count && GoogleDocLink.isValid(package.brainstormDocUrl ?? "")
    }

    private func docSection(_ package: BrainstormPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Brainstorm doc")
            TextField("https://docs.google.com/…", text: $docLink)
                .font(.bodyText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                .disabled(package.proofOfContact)
            HStack(spacing: 12) {
                if let url = URL(string: package.brainstormDocUrl ?? ""), GoogleDocLink.isValid(url.absoluteString) {
                    Link(destination: url) { Label("Open doc", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.brandSecondary)
                }
                if !package.proofOfContact {
                    Button(savingDoc ? "Saving…" : "Save link") { Task { await saveDoc(package) } }
                        .buttonStyle(.brandPrimary)
                        .disabled(savingDoc || !GoogleDocLink.isValid(docLink) || docLink == (package.brainstormDocUrl ?? ""))
                }
            }
        }
        .onAppear { if docLink.isEmpty { docLink = package.brainstormDocUrl ?? "" } }
    }

    private func proofsSection(_ package: BrainstormPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Proofs of contact")
            Text("Screenshots of your messages with three sources.").font(.small).foregroundStyle(Brand.secondary)
            HStack(spacing: 10) {
                ForEach(BrainstormPackage.proofSlots, id: \.self) { slot in
                    Button { if !package.proofOfContact { pickingSlot = slot } } label: {
                        ZStack {
                            if let proof = package.proof(in: slot) {
                                PortalImage(path: proof.imageUrl, api: api)
                            } else {
                                Brand.raised
                                VStack(spacing: 4) {
                                    Image(systemName: "plus").font(.system(size: 20))
                                    Text("Proof \(slot)").font(.small)
                                }
                                .foregroundStyle(Brand.muted)
                            }
                            if uploadingSlot == slot { Color.black.opacity(0.4); ProgressView().tint(.white) }
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
                        .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
                    }
                    .buttonStyle(.plain)
                    .disabled(package.proofOfContact || uploadingSlot != nil)
                    .accessibilityLabel(package.proof(in: slot) == nil ? "Add proof \(slot)" : "Replace proof \(slot)")
                }
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.brainstorm(nil))
        } catch {
            if state.value == nil { state = .failed(Loadable<BrainstormPayload>.message(for: error)) }
        }
    }

    private func saveDoc(_ package: BrainstormPackage) async {
        savingDoc = true
        defer { savingDoc = false }
        do {
            try await api.saveDocLink(package.id, docLink.trimmingCharacters(in: .whitespaces))
            message = ("Link saved.", true)
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
}
