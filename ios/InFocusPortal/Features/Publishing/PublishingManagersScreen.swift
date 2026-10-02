import SwiftUI

/// Website managers (producers manage the list): people who can read the
/// queue and published packages and copy YouTube embed codes, but never edit.
struct PublishingManagersScreen: View {
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<PublishingManagers> = .idle
    @State private var adding = false
    @State private var busyId: String?
    @State private var actionError: String?

    private var service: PublishingService { PublishingService(client: client) }

    var body: some View {
        LoadableView(state, retry: { Task { await load() } }) { roster in
            List {
                Section {
                    if roster.managers.isEmpty {
                        Text("No website managers yet.").foregroundStyle(Brand.secondary)
                    }
                    ForEach(roster.managers) { manager in
                        PersonRow(name: manager.name, email: manager.email, busy: busyId == manager.userId)
                            .swipeActions {
                                Button("Remove", role: .destructive) { Task { await remove(manager.userId) } }
                            }
                    }
                } footer: {
                    Text("They can view the queue and published packages and copy embed codes. Producers manage the queue.")
                        .font(.small)
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
            .sheet(isPresented: $adding) {
                ManagerPicker(candidates: roster.candidates.filter { candidate in
                    !roster.managers.contains { $0.userId == candidate.id }
                }) { candidate in
                    Task { await add(candidate.id) }
                }
            }
        }
        .brandBackground()
        .navigationTitle("Website managers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "person.badge.plus") { adding = true }
                    .disabled(state.value == nil)
            }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await service.managers())
        } catch PortalError.forbidden {
            state = .failed("Only producers manage website managers.")
        } catch {
            if state.value == nil { state = .failed(Loadable<PublishingManagers>.message(for: error)) }
        }
    }

    private func add(_ userId: String) async {
        await change(userId) { try await service.addManager(userId: userId) }
    }

    private func remove(_ userId: String) async {
        await change(userId) { try await service.removeManager(userId: userId) }
    }

    private func change(_ userId: String, _ action: () async throws -> Void) async {
        busyId = userId
        defer { busyId = nil }
        do {
            try await action()
            await load()
        } catch {
            actionError = Loadable<PublishingManagers>.message(for: error)
        }
    }
}

private struct PersonRow: View {
    let name: String?
    let email: String?
    var busy = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? email ?? "Someone").foregroundStyle(Brand.foreground)
                if let email, name != nil {
                    Text(email).font(.small).foregroundStyle(Brand.muted)
                }
            }
            Spacer()
            if busy { ProgressView() }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// Search the class and pick someone to make a website manager.
private struct ManagerPicker: View {
    let candidates: [PublishingManagers.Candidate]
    let pick: (PublishingManagers.Candidate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [PublishingManagers.Candidate] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return candidates }
        return candidates.filter {
            ($0.name ?? "").lowercased().contains(needle) || ($0.email ?? "").lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List(matches) { candidate in
                Button {
                    pick(candidate)
                    dismiss()
                } label: {
                    PersonRow(name: candidate.name, email: candidate.email)
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .searchable(text: $query, prompt: "Name or email")
            .navigationTitle("Add a website manager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
