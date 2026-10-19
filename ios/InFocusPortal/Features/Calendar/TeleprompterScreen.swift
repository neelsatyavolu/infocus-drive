import SwiftUI
import UIKit

/// The teleprompter, like the Portal's page on a phone: one script at a time with a Scripts
/// switcher, its sections to read and edit, and Run for the full-screen prompter.
struct TeleprompterScreen: View {
    let showDate: String?
    let docId: String?

    @Environment(\.portalClient) private var client
    @State private var model: TeleprompterModel?
    @State private var showScripts = false
    @State private var running = false
    @State private var editing: SectionDraft?
    @State private var titlePrompt: TitlePrompt?
    @State private var titleText = ""
    @State private var confirmDeleteDoc = false
    @State private var deletingSection: TeleprompterSection?

    var body: some View {
        Group {
            if let model {
                LoadableView(model.state, retry: { Task { await model.load() } }) { _ in content(model) }
            } else {
                SkeletonList(rows: 4)
            }
        }
        .brandBackground()
        .navigationTitle("Teleprompter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            if model == nil { model = TeleprompterModel(api: .current(client), showDate: showDate, docId: docId) }
            await model?.load()
        }
        .sheet(isPresented: $showScripts) {
            if let model {
                TeleprompterScriptsSheet(model: model) { titleText = ""; titlePrompt = .new }
            }
        }
        .sheet(item: $editing) { draft in
            if let model { TeleprompterSectionEditor(model: model, draft: draft) }
        }
        .fullScreenCover(isPresented: $running) {
            if let model { TeleprompterRunView(model: model) }
        }
        .alert(titlePrompt?.title ?? "", isPresented: Binding(get: { titlePrompt != nil }, set: { if !$0 { titlePrompt = nil } })) {
            TextField("Title", text: $titleText)
            Button("Save") { saveTitle() }
            Button("Cancel", role: .cancel) { titlePrompt = nil }
        }
        .confirmationDialog("Delete this script?", isPresented: $confirmDeleteDoc, titleVisibility: .visible) {
            Button("Delete script", role: .destructive) {
                if let id = model?.selectedId { Task { await model?.deleteDoc(id) } }
            }
        } message: {
            Text("Its sections are deleted too. This can't be undone.")
        }
        .confirmationDialog("Delete \(deletingSection?.label ?? "section")?",
                            isPresented: Binding(get: { deletingSection != nil }, set: { if !$0 { deletingSection = nil } }),
                            titleVisibility: .visible) {
            Button("Delete section", role: .destructive) {
                if let id = deletingSection?.id { Task { await model?.deleteSection(id) } }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { showScripts = true } label: { Label("Scripts", systemImage: "list.bullet.rectangle") }
                .disabled(model?.payload == nil)
        }
    }

    // MARK: Script

    @ViewBuilder
    private func content(_ model: TeleprompterModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = model.error { EditErrorBanner(message: error) }
                if let autofill = model.payload?.autofill, autofill.status != "ok", let message = autofill.message {
                    Label(message, systemImage: "info.circle")
                        .font(.small).foregroundStyle(Brand.warning)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Brand.warningTint, in: RoundedRectangle(cornerRadius: Brand.radius))
                }
                if let doc = model.selected {
                    header(doc, model: model)
                    if doc.sections.isEmpty {
                        EmptyStateView(title: "No sections yet", message: "Add a section for each part of the show.",
                                       actionTitle: model.canEdit ? "Add section" : nil) { newSection(model) }
                    }
                    ForEach(doc.sections) { section in
                        TeleprompterSectionCard(section: section, canEdit: model.canEdit, busy: model.working,
                                                jobRunning: model.jobTarget == section.id || model.jobTarget == "doc",
                                                onEdit: { editing = SectionDraft(section) },
                                                onJob: { job in Task { await model.runJob(job, on: section) } },
                                                onDelete: { deletingSection = section })
                    }
                } else {
                    EmptyStateView(title: "No scripts yet", message: "Show scripts appear here.",
                                   actionTitle: model.canEdit ? "New script" : nil) { titleText = ""; titlePrompt = .new }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.load() }
    }

    private func header(_ doc: TeleprompterDoc, model: TeleprompterModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Nameplate(eyebrow: showLine(doc), title: doc.title,
                      subtitle: "\(doc.sections.count) section\(doc.sections.count == 1 ? "" : "s")")
            HStack(spacing: 8) {
                Button { running = true } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.brandPrimary)
                    .disabled(doc.sections.isEmpty)
                if model.canEdit {
                    Button { newSection(model) } label: { Label("Section", systemImage: "plus") }
                        .buttonStyle(.brandSecondary)
                        .disabled(model.working)
                    Menu {
                        Button { titleText = doc.title; titlePrompt = .rename(doc.id) } label: { Label("Rename script", systemImage: "pencil") }
                        Button { Task { await model.reformatDoc(doc.id) } } label: { Label("Reformat all", systemImage: "sparkles") }
                            .disabled(doc.sections.isEmpty)
                        Button(role: .destructive) { confirmDeleteDoc = true } label: { Label("Delete script", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Script actions")
                    .disabled(model.working)
                }
            }
            if model.jobTarget == "doc" {
                HStack(spacing: 8) { ProgressView(); Text("Reformatting every section…").font(.small) }
            }
        }
    }

    private func showLine(_ doc: TeleprompterDoc) -> String {
        guard let key = TeleprompterScript.showDateKey(doc.showDate) else { return "Script" }
        if key == CalendarDates.todayKey() { return "Today's show" }
        return "Show · " + CalendarDates.weekdayShort(key) + " " + CalendarDates.dayNumber(key)
    }

    private func newSection(_ model: TeleprompterModel) {
        editing = SectionDraft(id: nil, label: model.nextLabel(), content: "")
    }

    private func saveTitle() {
        guard let prompt = titlePrompt, let model else { return }
        titlePrompt = nil
        let title = titleText
        Task {
            switch prompt {
            case .new: await model.saveDoc(title: title, renaming: nil)
            case .rename(let id): await model.saveDoc(title: title, renaming: id)
            }
        }
    }
}

/// New script or rename.
enum TitlePrompt: Equatable {
    case new
    case rename(String)

    var title: String {
        switch self {
        case .new: "New script"
        case .rename: "Rename script"
        }
    }
}

/// A section being written (`id` nil: a new one).
struct SectionDraft: Identifiable, Equatable {
    let id: String?
    var label: String
    var content: String

    init(id: String?, label: String, content: String) {
        self.id = id
        self.label = label
        self.content = content
    }

    init(_ section: TeleprompterSection) {
        self.init(id: section.id, label: section.label, content: section.content)
    }
}

/// One section to read: its code and beat, what's left to fill, and the text with [INSERT …]
/// placeholders marked.
struct TeleprompterSectionCard: View {
    let section: TeleprompterSection
    let canEdit: Bool
    let busy: Bool
    let jobRunning: Bool
    let onEdit: () -> Void
    let onJob: (TeleprompterAPI.SectionJob) -> Void
    let onDelete: () -> Void

    var body: some View {
        let parts = TeleprompterScript.displayParts(label: section.label, content: section.content)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(section.label).font(.mono(13)).foregroundStyle(Brand.green)
                if let beat = parts.beat { Text(beat).font(.lexend(15, .semibold, relativeTo: .headline)) }
                if let status = TeleprompterScript.status(of: section) {
                    StatusTag(text: status, tone: status == "To fill" ? .warning : .neutral)
                }
                Spacer(minLength: 0)
                if jobRunning { ProgressView().controlSize(.small) }
                if canEdit { menu }
            }
            if parts.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Nothing written yet.").font(.small).foregroundStyle(Brand.muted)
            } else {
                Text(highlighted(parts.content)).font(.bodyText).textSelection(.enabled)
            }
        }
        .card()
    }

    private var menu: some View {
        Menu {
            Button(action: onEdit) { Label("Edit section", systemImage: "pencil") }
            Button { UIPasteboard.general.string = section.content } label: { Label("Copy section", systemImage: "doc.on.doc") }
            Button { onJob(.reformat) } label: { Label("Reformat section", systemImage: "sparkles") }
            if section.label == "A2" {
                Button { onJob(.refetch) } label: { Label("Refetch bulletin", systemImage: "arrow.clockwise") }
            }
            Button(role: .destructive, action: onDelete) { Label("Delete section", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .disabled(busy)
        .accessibilityLabel("More actions for \(section.label)")
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString()
        for run in TeleprompterScript.placeholderRuns(text) {
            var part = AttributedString(run.text)
            if run.placeholder {
                part.foregroundColor = Brand.warning
                part.font = .lexend(15, .semibold, relativeTo: .body)
            }
            result += part
        }
        return result
    }
}
