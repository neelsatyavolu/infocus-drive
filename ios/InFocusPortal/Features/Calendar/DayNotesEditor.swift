import SwiftUI

/// A class day's or a holiday's notes, like the Portal's Master Calendar cell: the text, package
/// pills (each one marks its package aired on that day; rename or remove it), and on a class day
/// the scenic image switch. Plain paragraphs are edited here; formatted parts (bold, lists…) show
/// as the Portal shows them and are kept exactly, with a link to edit them on the Portal.
struct DayNotesEditor: View {
    let date: String
    let kind: DayKind
    let content: String
    let busy: Bool
    let editor: CalendarDayEditor?

    @Environment(Router.self) private var router
    @State private var doc = CalendarNotesDocument.parse("")
    /// The cell `doc` was read from; a save checks the Portal still has it.
    @State private var base = ""
    @State private var addingPackage = false
    @State private var renaming: CalendarNotes.Pill?
    @State private var renameText = ""

    private var imageHidden: Bool { CalendarNotes.isImageHidden(content) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if kind == .none { scenicImage }
            notes
        }
        .onAppear(perform: syncFromStore)
        .onChange(of: content) { _, _ in if !doc.isDirty { syncFromStore() } }
        .sheet(isPresented: $addingPackage) {
            PackagePickerSheet(taken: Set(doc.pills.map(\.id))) { option in
                doc.addPill(id: option.id, label: option.title)
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
        doc = CalendarNotesDocument.parse(content)
        base = content
    }

    // MARK: Scenic image

    private var scenicImage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CastSectionHeader(title: "Scenic image", detail: "Shown on class days in the calendar")
                if imageHidden { StatusTag(text: "Image off") }
            }
            if !imageHidden, let url = CalendarNotes.scenicImage(for: date) {
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
                Label(imageHidden ? "Restore image" : "Delete image",
                      systemImage: imageHidden ? "photo" : "photo.badge.minus")
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
            ForEach(Array(doc.blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .text: textField(at: index)
                case .rich(let html): formatted(html)
                case .pill: EmptyView() // listed under Packages
                }
            }
            if doc.hasFormatting {
                Button("Edit formatting on the Portal") {
                    router.openPortal("master-calendar?date=\(date)", title: "Master Calendar")
                }
                .font(.small)
                .tint(Brand.green)
            }
            if !doc.pills.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Packages", color: Brand.muted)
                    ForEach(doc.pills) { pill in pillRow(pill) }
                }
            }
            Button("Save notes") { Task { await save() } }
                .buttonStyle(.brandPrimary)
                .disabled(busy || !doc.isDirty)
            if doc.isDirty {
                Button("Discard changes", role: .destructive) { syncFromStore() }
                    .buttonStyle(.brandSecondary)
                    .disabled(busy)
            }
            Text("Adding a package marks it aired on this day. Removing it puts it back.")
                .font(.small)
                .foregroundStyle(Brand.muted)
        }
        .card()
    }

    private func textField(at index: Int) -> some View {
        TextField("Notes", text: Binding(get: { doc.text(at: index) }, set: { doc.setText($0, at: index) }), axis: .vertical)
            .font(.bodyText)
            .lineLimit(3...)
            .padding(12)
            .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
            .accessibilityLabel("Notes")
            .disabled(busy)
    }

    /// Formatted text from the Portal: shown as it looks there, kept exactly as stored.
    private func formatted(_ html: String) -> some View {
        let text = CalendarRichText.attributed(html)
        return Group {
            if !text.characters.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(text).font(.bodyText).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "lock").font(.small).foregroundStyle(Brand.muted)
                        .accessibilityLabel("Formatted on the Portal; edit it there")
                }
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
            }
        }
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
                Button(role: .destructive) { doc.removePill(id: pill.id) } label: { Label("Remove", systemImage: "trash") }
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
        let body = doc.body()
        await editor.setNotes(body, basedOn: base)
        // Saved: what was sent is the new base, so the store's fresh copy replaces it on arrival.
        if editor.error == nil {
            doc = CalendarNotesDocument.parse(body)
            base = body
        }
    }

    private func rename() {
        defer { renaming = nil }
        let label = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = renaming, !label.isEmpty else { return }
        doc.renamePill(id: target.id, label: label)
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
