import SwiftUI

/// Admin → People: everyone who can sign in. Add someone (and email them an invite),
/// set a nickname, or delete a person's account (their work stays, unattributed).
struct PeopleScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @State private var state: Loadable<[PlatformPerson]> = .idle
    @State private var notAvailable = false
    @State private var query = ""
    @State private var adding = false
    @State private var editing: PlatformPerson?
    @State private var notice: String?

    private var service: AdminService { AdminService(client: client) }

    var body: some View {
        Group {
            if notAvailable {
                NotAvailableView(message: "People is for executive producers and up.")
            } else {
                LoadableView(state, retry: { Task { await load() } }) { people in
                    list(PeopleSearch.filter(people, query))
                }
            }
        }
        .brandBackground()
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Name or email")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add person", systemImage: "person.badge.plus") { adding = true }
                    .disabled(state.value == nil)
            }
        }
        .sheet(isPresented: $adding) {
            AddPersonSheet(service: service) { message in
                notice = message
                Task { await load() }
            }
        }
        .sheet(item: $editing) { person in
            PersonSheet(person: person, isYou: person.email?.lowercased() == session.user?.email.lowercased(),
                        service: service) { message in
                notice = message
                Task { await load() }
            }
        }
        .task { await load() }
    }

    private func list(_ people: [PlatformPerson]) -> some View {
        List {
            if let notice {
                Text(notice).font(.small).foregroundStyle(Brand.green)
            }
            Section {
                if people.isEmpty {
                    Text(query.isEmpty ? "No one yet." : "No one matches.").foregroundStyle(Brand.secondary)
                }
                ForEach(people) { person in
                    Button { editing = person } label: {
                        HStack {
                            PersonLine(title: person.label, detail: person.email)
                            if !person.hasSignedIn { StatusTag(text: "Invited") }
                        }
                    }
                }
            } footer: {
                Text("People sign in with the Google account for their email.").font(.small)
            }
        }
        .toolsList()
        .refreshable { await load() }
    }

    private func load() async {
        await ToolLoad.run($state, notAvailable: $notAvailable) { try await service.people() }
    }
}

/// Search on nickname, name and email (trimmed, any case).
enum PeopleSearch {
    static func filter(_ people: [PlatformPerson], _ query: String) -> [PlatformPerson] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return people }
        return people.filter { person in
            [person.nickname, person.name, person.email].contains { $0?.lowercased().contains(needle) == true }
        }
    }
}

/// Add person: full name and email; they sign in with that Google account.
private struct AddPersonSheet: View {
    let service: AdminService
    let added: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var sendInvite = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Full name", text: $name)
                        .textContentType(.name)
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Email them an invite to sign in", isOn: $sendInvite)
                } footer: {
                    Text("They sign in with the Google account for this email.")
                }
                if let error {
                    Text(error).font(.small).foregroundStyle(Brand.danger)
                }
            }
            .toolsList()
            .navigationTitle("Add person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Add") { Task { await add() } } }
                }
            }
        }
    }

    private func add() async {
        let name = name.trimmingCharacters(in: .whitespaces)
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !email.isEmpty else { return error = "Enter a name and email." }
        guard AdminFormat.isEmail(email) else { return error = "Enter a valid email address." }
        saving = true
        defer { saving = false }
        do {
            let result = try await service.addPerson(name: name, email: email, sendInvite: sendInvite)
            let invited = (result.emailed ?? 0) > 0
            added(sendInvite ? (invited ? "\(name) can sign in. Invite email sent." : "\(name) can sign in. Invite email was not sent.")
                  : "\(name) can sign in with Google.")
            dismiss()
        } catch {
            self.error = Loadable<Int>.message(for: error)
        }
    }
}

/// One person: nickname, and deleting their account.
private struct PersonSheet: View {
    let person: PlatformPerson
    let isYou: Bool
    let service: AdminService
    let changed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String
    @State private var busy = false
    @State private var confirmingDelete = false
    @State private var error: String?

    init(person: PlatformPerson, isYou: Bool, service: AdminService, changed: @escaping (String) -> Void) {
        self.person = person
        self.isYou = isYou
        self.service = service
        self.changed = changed
        _nickname = State(initialValue: person.nickname ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Name", value: person.name ?? "Not set")
                    LabeledContent("Email", value: person.email ?? "None")
                    LabeledContent("Added", value: AdminFormat.when(person.createdAt))
                }
                Section {
                    TextField("Nickname", text: $nickname)
                        .onChange(of: nickname) { _, value in if value.count > 60 { nickname = String(value.prefix(60)) } }
                } header: {
                    Text("Nickname")
                } footer: {
                    Text("Shown on rosters, calendars and comments. Leave empty to use their name.")
                }
                if !isYou {
                    Section {
                        Button("Delete person", role: .destructive) { confirmingDelete = true }
                            .frame(maxWidth: .infinity)
                    } footer: {
                        Text("Their uploads and comments stay, shown as a deleted user. They can't sign in again unless someone adds them back.")
                    }
                }
                if let error {
                    Text(error).font(.small).foregroundStyle(Brand.danger)
                }
            }
            .toolsList()
            .navigationTitle(person.label)
            .navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Save") { Task { await saveNickname() } }
                            .disabled(trimmed == (person.nickname ?? ""))
                    }
                }
            }
            .confirmationDialog("Delete \(person.label)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("This removes their account and role. It can't be undone.")
            }
        }
    }

    private var trimmed: String { nickname.trimmingCharacters(in: .whitespaces) }

    private func saveNickname() async {
        await run {
            try await service.setNickname(trimmed.isEmpty ? nil : trimmed, for: person.id)
            changed("Saved \(trimmed.isEmpty ? person.name ?? person.label : trimmed)'s nickname.")
        }
    }

    private func delete() async {
        await run {
            try await service.deletePerson(person.id)
            changed("Deleted \(person.label).")
        }
    }

    private func run(_ action: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await action()
            dismiss()
        } catch {
            self.error = Loadable<Int>.message(for: error)
        }
    }
}
