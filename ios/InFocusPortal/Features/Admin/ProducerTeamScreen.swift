import SwiftUI

/// Admin → Producer team: associate producers, executive producers and the adviser,
/// grouped by role. Everyone in Admin can read it; the super admin assigns and removes roles.
struct ProducerTeamScreen: View {
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<ProducerTeam> = .idle
    @State private var notAvailable = false
    @State private var assigning = false
    @State private var busyEmail: String?
    @State private var removing: RoleAssignment?
    @State private var actionError: String?

    private var service: AdminService { AdminService(client: client) }

    var body: some View {
        Group {
            if notAvailable {
                NotAvailableView(message: "The producer team is for executive producers and up.")
            } else {
                LoadableView(state, retry: { Task { await load() } }) { team in
                    list(team)
                }
            }
        }
        .brandBackground()
        .navigationTitle("Producer team")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if state.value?.canManage == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Assign role", systemImage: "plus") { assigning = true }
                }
            }
        }
        .sheet(isPresented: $assigning) {
            if let team = state.value {
                AssignRoleSheet(people: team.people.filter { $0.email != nil }) { email, role in
                    Task { await assign(role, to: email) }
                }
            }
        }
        .confirmationDialog("Remove \(removing.map { state.value?.label(for: $0) ?? $0.email } ?? "")'s role?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove role", role: .destructive) {
                if let entry = removing { Task { await remove(entry) } }
            }
        } message: {
            Text("They keep their account but lose producer access.")
        }
        .actionErrorAlert($actionError)
        .task { await load() }
    }

    private func list(_ team: ProducerTeam) -> some View {
        List {
            ForEach(team.groups, id: \.role) { group in
                Section(group.role.label) {
                    ForEach(group.entries) { entry in
                        PersonLine(title: team.label(for: entry), detail: entry.email, busy: busyEmail == entry.email)
                            .swipeActions {
                                if team.canManage {
                                    Button("Remove", role: .destructive) { removing = entry }
                                }
                            }
                    }
                }
            }
            if team.groups.isEmpty {
                Text("No roles assigned yet.").foregroundStyle(Brand.secondary)
            }
            if !team.canManage {
                Text("Only the super admin and the adviser change roles.").font(.small).foregroundStyle(Brand.muted)
            }
        }
        .toolsList()
        .refreshable { await load() }
    }

    private func load() async {
        await ToolLoad.run($state, notAvailable: $notAvailable) {
            async let access = service.access()
            async let roles = service.roles()
            async let people = service.people()
            return ProducerTeam(roles: try await roles, people: try await people,
                                canManage: try await access.permissions.canManagePlatformRoles)
        }
    }

    private func assign(_ role: AssignableRole, to email: String) async {
        await change(email) { try await service.setRole(role, email: email) }
    }

    private func remove(_ entry: RoleAssignment) async {
        await change(entry.email) { try await service.removeRole(email: entry.email) }
    }

    private func change(_ email: String, _ action: () async throws -> Void) async {
        busyEmail = email
        defer { busyEmail = nil }
        do {
            try await action()
            await load()
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }
}

/// Role assignments grouped the way the web shows them, with names from the people list.
struct ProducerTeam: Sendable {
    struct RoleGroup: Sendable {
        let role: PlatformRole
        let entries: [RoleAssignment]
    }

    let roles: [RoleAssignment]
    let people: [PlatformPerson]
    let canManage: Bool

    static let order: [PlatformRole] = [.superAdmin, .adviser, .executiveProducer, .associateProducer]

    var groups: [RoleGroup] {
        Self.order.compactMap { role in
            let entries = roles.filter { $0.platformRole == role }.sorted { $0.email < $1.email }
            return entries.isEmpty ? nil : RoleGroup(role: role, entries: entries)
        }
    }

    func label(for entry: RoleAssignment) -> String {
        people.first { $0.email?.lowercased() == entry.email.lowercased() }?.label ?? entry.email
    }
}

/// Pick a person and a role (assigning replaces any role they had).
private struct AssignRoleSheet: View {
    let people: [PlatformPerson]
    let assign: (String, AssignableRole) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var role: AssignableRole = .associateProducer

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Role", selection: $role) {
                        ForEach(AssignableRole.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Person") {
                    ForEach(PeopleSearch.filter(people, query)) { person in
                        Button {
                            if let email = person.email { assign(email, role) }
                            dismiss()
                        } label: {
                            PersonLine(title: person.label, detail: person.email)
                        }
                    }
                }
            }
            .toolsList()
            .searchable(text: $query, prompt: "Name or email")
            .navigationTitle("Assign role")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
