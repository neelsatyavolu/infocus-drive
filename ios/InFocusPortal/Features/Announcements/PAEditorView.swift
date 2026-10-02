import SwiftUI

/// The PA script for the next PA (read at the start of second period on school Mondays unless
/// the bell schedule changes). Assigned announcers and producers edit it; changes are shared
/// with the PA team, so leaving with unsaved edits asks first.
struct PAEditorView: View {
    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model = PAEditorModel()
    @State private var confirm: Confirmation?
    @FocusState private var editing: Bool

    private enum Confirmation: Identifiable {
        case discard, regenerate, leave
        var id: Self { self }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Nameplate(eyebrow: "InFocus announcements", title: "PA", subtitle: model.page?.dateLabel)
                LoadableView(model.state, retry: { Task { await model.load(api: api, force: true) } }) { page in
                    content(page)
                }
            }
            .padding(Brand.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .brandBackground()
        .navigationTitle("PA")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.dirty)
        .toolbar { toolbar }
        .refreshable { if model.canRefresh { await model.load(api: api, force: true) } }
        .task { await model.load(api: api) }
        .confirmationDialog(title, isPresented: confirmShown, titleVisibility: .visible, presenting: confirm) { kind in
            confirmButtons(kind)
        } message: { kind in
            Text(message(kind))
        }
    }

    private var api: AnnouncementsAPI { AnnouncementsAPI.current(client) }

    @ViewBuilder
    private func content(_ page: PAPage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.error { MessageBanner(text: error) }
            if let note = page.autofill?.message { MessageBanner(text: note) }
            if page.date != nil, page.script != nil {
                if let time = page.timeLabel { StatusTag(text: time) }
                editor(page)
                PAAnnouncersCard(announcers: page.announcers) {
                    if let portal = AppConfig.shared.portalURL { router.open(portal.appendingPathComponent("master-calendar")) }
                }
                PAGuideCard { router.push(.announcements(.submitted)) }
            } else {
                EmptyStateView(title: "No upcoming PA",
                               message: "There are no remaining PA dates on the school calendar.")
            }
        }
    }

    private func editor(_ page: PAPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PA script").headline(.h3)
                    Text(model.canEdit ? "Edit the shared script, then save before leaving."
                                       : "Assigned announcers and producers can edit this script.")
                        .font(.small).foregroundStyle(Brand.muted)
                }
                Spacer(minLength: 8)
                Text(model.statusText)
                    .font(.small)
                    .foregroundStyle(model.dirty ? Brand.warning : Brand.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if model.canEdit {
                TextEditor(text: $model.draft)
                    .font(.bodyText)
                    .lineSpacing(6)
                    .focused($editing)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 420)
                    .background(Brand.background, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(editing ? Brand.green : Brand.control))
                    .disabled(model.activity != nil)
                    .accessibilityLabel("PA script for \(page.dateLabel)")
                actions
            } else {
                Text(model.draft)
                    .font(.bodyText)
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { Task { await model.save(api: api) } } label: {
                Label(model.activity == .saving ? "Saving…" : "Save script", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.brandPrimary)
            .disabled(!model.canSave)
            HStack(spacing: 10) {
                if model.dirty {
                    Button("Discard changes") { confirm = .discard }
                        .buttonStyle(.brandSecondary)
                        .disabled(model.activity != nil)
                }
                Button { confirm = .regenerate } label: {
                    Label(model.activity == .regenerating ? "Regenerating…" : "Regenerate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.brandSecondary)
                .disabled(!model.canRegenerate)
            }
            Text("Changes are shared with your PA team.").font(.small).foregroundStyle(Brand.muted)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.dirty {
            ToolbarItem(placement: .topBarLeading) {
                Button { confirm = .leave } label: {
                    Label("Back", systemImage: "chevron.backward").labelStyle(.titleAndIcon)
                }
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { editing = false }
        }
    }

    // MARK: Confirmations

    private var title: String {
        switch confirm {
        case .regenerate: "Regenerate the PA script?"
        case .discard, .leave, nil: "Discard your changes?"
        }
    }

    private func message(_ kind: Confirmation) -> String {
        switch kind {
        case .regenerate:
            "This replaces the shared script and any unsaved edits with a new script using the latest announcements and assigned names. The result is saved for your PA team."
        case .discard, .leave:
            "Your unsaved edits will be removed. The saved script will stay unchanged."
        }
    }

    @ViewBuilder
    private func confirmButtons(_ kind: Confirmation) -> some View {
        switch kind {
        case .regenerate:
            Button("Regenerate script", role: .destructive) { Task { await model.regenerate(api: api) } }
        case .discard:
            Button("Discard changes", role: .destructive) { model.discard() }
        case .leave:
            Button("Discard and go back", role: .destructive) {
                model.discard()
                dismiss()
            }
        }
        Button("Keep editing", role: .cancel) {}
    }

    private var confirmShown: Binding<Bool> {
        Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })
    }
}
