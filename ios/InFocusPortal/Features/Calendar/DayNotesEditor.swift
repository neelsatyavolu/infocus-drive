import SwiftUI

/// A class day's or a holiday's notes, like the Portal's Master Calendar cell: the text, package
/// pills (each one marks its package aired on that day; rename or remove it), and on a class day
/// the scenic image switch.
struct DayNotesEditor: View {
    let date: String
    let kind: DayKind
    let content: String
    let busy: Bool
    let editor: CalendarDayEditor?

    @State private var text = ""
    @State private var pills: [CalendarNotes.Pill] = []
    @State private var loadedFrom: String?
    @State private var addingPackage = false
    @State private var renaming: CalendarNotes.Pill?
    @State private var renameText = ""

    private var stored: CalendarNotes { CalendarNotes.parse(content) }
    /// Edits not saved yet, against the cell this editor last loaded.
    private var dirty: Bool {
        guard let loadedFrom else { return false }
        let base = CalendarNotes.parse(loadedFrom)
        return text != base.text || pills != base.pills
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if kind == .none { scenicImage }
            notes
        }
        .onAppear(perform: syncFromStore)
        .onChange(of: content) { _, _ in if !dirty { syncFromStore() } }
        .sheet(isPresented: $addingPackage) {
            PackagePickerSheet(taken: Set(pills.map(\.id))) { option in
                pills.append(.init(id: option.id, label: option.title))
            }
        }
        .alert("Rename package", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Label", text: $renameText)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Only the label on the calendar changes. The package stays the same.")
        }
    }

    private func syncFromStore() {
        let parsed = stored
        text = parsed.text
        pills = parsed.pills
        loadedFrom = content
    }

    // MARK: Scenic image

    private var scenicImage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CastSectionHeader(title: "Scenic image", detail: "Shown on class days in the calendar")
                if stored.imageHidden { StatusTag(text: "Image off") }
            }
            if !stored.imageHidden, let url = CalendarNotes.scenicImage(for: date) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Brand.raised
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
                .accessibilityLabel("Royalty-free scenic view")
            }
            Button {
                Task { await editor?.toggleImage() }
            } label: {
                Label(stored.imageHidden ? "Restore image" : "Delete image",
                      systemImage: stored.imageHidden ? "photo" : "photo.badge.minus")
            }
            .buttonStyle(.brandSecondary)
            .disabled(busy)
        }
        .card()
    }

    // MARK: Notes and pills

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            CastSectionHeader(title: "Notes", detail: "What's happening this day",
                              action: ("Add package", "plus", { addingPackage = true }), disabled: busy)
            TextEditor(text: $text)
                .font(.bodyText)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
                .accessibilityLabel("Notes")
            if !pills.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Packages", color: Brand.muted)
                    ForEach(pills) { pill in pillRow(pill) }
                }
            }
            Button("Save notes") { Task { await save() } }
                .buttonStyle(.brandPrimary)
                .disabled(busy || !dirty)
            Text("Adding a package marks it aired on this day. Removing it puts it back.")
                .font(.small)
                .foregroundStyle(Brand.muted)
        }
        .card()
    }

    private func pillRow(_ pill: CalendarNotes.Pill) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "film").foregroundStyle(Brand.green).accessibilityHidden(true)
            Text(pill.label.isEmpty ? "Untitled package" : pill.label)
                .font(.lexend(15, .medium, relativeTo: .body))
                .lineLimit(2)
            Spacer(minLength: 0)
            Menu {
                Button { renameText = pill.label; renaming = pill } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { pills.removeAll { $0.id == pill.id } } label: { Label("Remove", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(pill.label)")
            .disabled(busy)
        }
        .padding(.leading, 10)
        .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
    }

    private func save() async {
        guard let editor else { return }
        await editor.setNotes(text, pills: pills)
        if editor.error == nil { syncFromStore() }
    }

    private func rename() {
        defer { renaming = nil }
        let label = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = renaming, !label.isEmpty else { return }
        pills = pills.map { $0.id == target.id ? CalendarNotes.Pill(id: $0.id, label: label) : $0 }
    }
}

/// Search the Portal's media for a package to add as a pill (`GET api/master-calendar/packages`).
struct PackagePickerSheet: View {
    let taken: Set<String>
    let onPick: (CalendarPackageOption) -> Void

    @Environment(\.portalClient) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var state: Loadable<[CalendarPackageOption]> = .idle

    var body: some View {
        NavigationStack {
            List {
                switch state {
                case .idle:
                    Text("Search by package or project name.").font(.small).foregroundStyle(Brand.muted)
                case .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").font(.small).foregroundStyle(Brand.danger)
                case .loaded(let options) where options.isEmpty:
                    Text("No packages match.").font(.small).foregroundStyle(Brand.muted)
                case .loaded(let options):
                    ForEach(options) { option in row(option) }
                }
            }
            .scrollContentBackground(.hidden)
            .brandBackground()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Package or project")
            .navigationTitle("Add package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: query) { await search() }
        }
    }

    private func row(_ option: CalendarPackageOption) -> some View {
        let added = taken.contains(option.id)
        return Button {
            onPick(option)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(.lexend(16, .medium, relativeTo: .body)).foregroundStyle(Brand.foreground)
                    Text(option.projectName).font(.small).foregroundStyle(Brand.muted)
                }
                Spacer()
                if added {
                    StatusTag(text: "Added")
                } else if let status = option.statusLabel {
                    StatusTag(text: status, tone: option.approvalStatus == "APPROVED" ? .success : .neutral)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(added)
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { state = .idle; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        state = .loading
        do {
            state = .loaded(try await CalendarEditAPI.current(client).searchPackages(String(trimmed.prefix(120))))
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(Loadable<[CalendarPackageOption]>.message(for: error))
        }
    }
}
