import SwiftUI

/// Every script, newest show first, with the one status the Portal's rail shows; pick one to open it.
struct TeleprompterScriptsSheet: View {
    let model: TeleprompterModel
    let onNew: () -> Void

    @Environment(\.dismiss) private var dismiss
    private let today = CalendarDates.todayKey()

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.docs) { doc in
                    Button {
                        model.selectedId = doc.id
                        dismiss()
                    } label: {
                        row(doc)
                    }
                    .accessibilityAddTraits(doc.id == model.selectedId ? .isSelected : [])
                }
            }
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Scripts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if model.canEdit {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            dismiss()
                            onNew()
                        } label: { Label("New script", systemImage: "plus") }
                    }
                }
            }
        }
    }

    private func row(_ doc: TeleprompterDoc) -> some View {
        let key = TeleprompterScript.showDateKey(doc.showDate)
        return HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(key.map { CalendarDates.weekdayShort($0).uppercased() } ?? "—")
                    .font(.lexend(11, .medium, relativeTo: .caption2)).tracking(1.2).foregroundStyle(Brand.muted)
                Text(key.map { String($0.dropFirst(5)).replacingOccurrences(of: "-", with: "/") } ?? "")
                    .font(.mono(13)).foregroundStyle(Brand.foreground)
            }
            .frame(width: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title).font(.lexend(16, .medium, relativeTo: .body)).foregroundStyle(Brand.foreground).lineLimit(2)
                if let status = TeleprompterScript.docStatus(doc, today: today, nextShow: model.nextShowKey) {
                    StatusTag(text: status.label, tone: status.warning ? .warning : .success)
                }
            }
            Spacer(minLength: 0)
            if doc.id == model.selectedId {
                Image(systemName: "checkmark").foregroundStyle(Brand.green).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Write or edit one section: its label (A1, A2…) and the script. Cues like `ANCHOR:`, `{ROLL PACKAGE}`
/// and `[RED]…[/RED]` show in run mode as on the web.
struct TeleprompterSectionEditor: View {
    let model: TeleprompterModel
    @State var draft: SectionDraft

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.error { EditErrorBanner(message: error) }
                TextField("Label", text: $draft.label)
                    .font(.mono(16))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .accessibilityLabel("Section label")
                TextEditor(text: $draft.content)
                    .font(.bodyText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .accessibilityLabel("Script")
                Text("ANCHOR: and COANCHOR: start a cue. {ROLL PACKAGE} is a cue on its own line. [RED]text[/RED] shows red.")
                    .font(.small)
                    .foregroundStyle(Brand.muted)
            }
            .padding(Brand.gutter)
            .brandBackground()
            .navigationTitle(draft.id == nil ? "New section" : "Edit \(draft.label)")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.working)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.working {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(draft.label.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear { model.error = nil }
        }
    }

    private func save() async {
        if await model.saveSection(id: draft.id, label: draft.label, content: draft.content) { dismiss() }
    }
}
