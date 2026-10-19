import SwiftUI

/// Add or edit a login (producers). Saved secrets are write-only: keep, replace or
/// remove them. Saved notes load (a logged view) only when you choose to edit them.
struct VaultEditorSheet: View {
    let entry: VaultEntry?
    let service: VaultService
    /// `true` when the login was deleted.
    let saved: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var username: String
    @State private var password = ""
    @State private var showPassword = false
    @State private var passwordMode: VaultSecretMode
    @State private var totp = ""
    @State private var totpMode: VaultSecretMode
    @State private var notes = ""
    @State private var notesLoaded: Bool
    @State private var busy: String?
    @State private var confirmingDelete = false
    @State private var error: String?

    init(entry: VaultEntry?, service: VaultService, saved: @escaping (Bool) -> Void) {
        self.entry = entry
        self.service = service
        self.saved = saved
        _name = State(initialValue: entry?.name ?? "")
        _url = State(initialValue: entry?.url ?? "")
        _username = State(initialValue: entry?.username ?? "")
        _passwordMode = State(initialValue: entry?.hasPassword == true ? .keep : .replace)
        _totpMode = State(initialValue: entry?.hasTotp == true ? .keep : .replace)
        _notesLoaded = State(initialValue: entry?.hasNotes != true)
    }

    /// Convenience for the list's Add button.
    init(entry: VaultEntry?, service: VaultService, saved: @escaping () -> Void) {
        self.init(entry: entry, service: service) { (_: Bool) in saved() }
    }

    private var editing: Bool { entry != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("InFocus YouTube"))
                        .onChange(of: name) { _, value in
                            if value.count > VaultEntryInput.nameMax { name = String(value.prefix(VaultEntryInput.nameMax)) }
                        }
                    TextField("Website", text: $url, prompt: Text("youtube.com"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username or email", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Password") {
                    secretControls(mode: $passwordMode, label: "password") {
                        HStack {
                            Group {
                                if showPassword {
                                    TextField(entry?.hasPassword == true ? "New password" : "Password", text: $password)
                                } else {
                                    SecureField(entry?.hasPassword == true ? "New password" : "Password", text: $password)
                                }
                            }
                            .font(.mono(15))
                            .textContentType(.newPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye").frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                        }
                        Button("Suggest a strong password") {
                            password = VaultEntryInput.strongPassword()
                            showPassword = true
                        }
                    }
                }
                Section {
                    secretControls(mode: $totpMode, label: "2FA key") {
                        TextField("Setup key or otpauth:// link", text: $totp, prompt: Text("JBSW Y3DP EHPK 3PXP"))
                            .font(.mono(15))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("2FA")
                } footer: {
                    Text("The base32 setup key or the otpauth:// link from the site's 2FA setup.")
                }
                Section {
                    if notesLoaded {
                        TextField("Recovery codes, security answers, who owns the account", text: $notes, axis: .vertical)
                            .lineLimit(3...10)
                    } else {
                        HStack {
                            Label("Saved (encrypted)", systemImage: "lock").foregroundStyle(Brand.muted)
                            Spacer()
                            Button(busy == "notes" ? "Loading…" : "Edit notes") { Task { await loadNotes() } }
                                .disabled(busy != nil)
                        }
                    }
                } header: {
                    Text("Notes")
                } footer: {
                    if !notesLoaded { Text("Loading the notes to edit them is logged as a view.") }
                }
                if let entry, entry.canDelete {
                    Section {
                        Button("Delete login", role: .destructive) { confirmingDelete = true }
                            .frame(maxWidth: .infinity)
                    }
                }
                if let error {
                    Text(error).font(.small).foregroundStyle(Brand.danger)
                }
            }
            .toolsList()
            .navigationTitle(entry.map { "Edit \($0.name)" } ?? "Add password")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(busy == "save" || busy == "delete")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy == "save" { ProgressView() } else {
                        Button(editing ? "Save" : "Add") { Task { await save() } }
                            .disabled(busy != nil)
                    }
                }
            }
            .confirmationDialog("Delete \(entry?.name ?? "this login")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("Everyone loses this login. It can't be undone.")
            }
        }
    }

    /// A saved secret shows Saved + Replace / Remove (or Undo); otherwise the field.
    @ViewBuilder
    private func secretControls<Field: View>(mode: Binding<VaultSecretMode>, label: String,
                                             @ViewBuilder field: () -> Field) -> some View {
        switch mode.wrappedValue {
        case .replace:
            field()
        case .keep:
            Label("Saved (encrypted)", systemImage: "lock").foregroundStyle(Brand.muted)
            Button("Replace the \(label)") { mode.wrappedValue = .replace }
            Button("Remove the \(label)", role: .destructive) { mode.wrappedValue = .remove }
        case .remove:
            Label("Will be removed when you save", systemImage: "lock.slash").foregroundStyle(Brand.warning)
            Button("Undo") { mode.wrappedValue = .keep }
        }
    }

    private func loadNotes() async {
        guard let entry else { return }
        busy = "notes"
        defer { busy = nil }
        do {
            notes = try await service.reveal("notes", of: entry.id)
            notesLoaded = true
        } catch {
            self.error = Loadable<Int>.message(for: error)
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return error = "Name is required." }
        let input = VaultEntryInput(name: trimmed, url: url, username: username,
                                    password: VaultEntryInput.secret(passwordMode, password, editing: editing),
                                    totp: VaultEntryInput.secret(totpMode, totp, editing: editing),
                                    notes: notesLoaded ? notes : nil)
        busy = "save"
        defer { busy = nil }
        do {
            if let entry {
                try await service.update(entry.id, input)
            } else {
                try await service.create(input)
            }
            password = ""
            saved(false)
            dismiss()
        } catch {
            self.error = Loadable<Int>.message(for: error)
        }
    }

    private func delete() async {
        guard let entry else { return }
        busy = "delete"
        defer { busy = nil }
        do {
            try await service.delete(entry.id)
            saved(true)
            dismiss()
        } catch {
            self.error = Loadable<Int>.message(for: error)
        }
    }
}

/// Share a login with people outside the vault (executive producers and up).
struct VaultShareSheet: View {
    let entry: VaultEntry
    let service: VaultService
    let saved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: Loadable<[VaultPeople.Person]> = .idle
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            LoadableView(state, retry: { Task { await load() } }) { people in
                List {
                    Section {
                        ForEach(matches(people)) { person in
                            Button {
                                if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
                            } label: {
                                HStack {
                                    Text(person.name).foregroundStyle(Brand.foreground)
                                    Spacer()
                                    Image(systemName: selected.contains(person.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(person.id) ? Brand.green : Brand.control)
                                }
                                .frame(minHeight: 44)
                            }
                            .accessibilityAddTraits(selected.contains(person.id) ? .isSelected : [])
                        }
                    } footer: {
                        Text("They can use this login (username, password and 2FA code) but can't see notes or edit it. Producers already see every login.")
                    }
                    if let error {
                        Text(error).font(.small).foregroundStyle(Brand.danger)
                    }
                }
                .toolsList()
                .searchable(text: $query, prompt: "Name")
            }
            .brandBackground()
            .navigationTitle("Share \(entry.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") { Task { await save() } }.disabled(state.value == nil)
                    }
                }
            }
            .task { await load() }
        }
    }

    private func matches(_ people: [VaultPeople.Person]) -> [VaultPeople.Person] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = people.sorted { (selected.contains($0.id) ? 0 : 1, $0.name) < (selected.contains($1.id) ? 0 : 1, $1.name) }
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { $0.name.lowercased().contains(needle) }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let sharing = try await service.sharing(of: entry.id)
            selected = Set(sharing.shared.map(\.id))
            // Someone shared already but missing from candidates still shows.
            let extra = sharing.shared.filter { person in !sharing.candidates.contains { $0.id == person.id } }
            state = .loaded(sharing.candidates + extra)
        } catch {
            state = .failed(Loadable<Int>.message(for: error))
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await service.setSharing(of: entry.id, userIds: Array(selected).sorted())
            saved()
            dismiss()
        } catch {
            self.error = Loadable<Int>.message(for: error)
        }
    }
}
