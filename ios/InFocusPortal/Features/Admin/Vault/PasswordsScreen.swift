import SwiftUI

/// More → Passwords, the native `/passwords`: the class's shared logins. Associate
/// producers and up see and manage every login; anyone else sees only logins an
/// executive producer shared with them (use them, never edit). Secrets are revealed
/// one at a time on the login's screen, and the Portal logs each reveal.
struct PasswordsScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @State private var state: Loadable<[VaultEntry]> = .idle
    @State private var notAvailable = false
    @State private var query = ""
    @State private var sharedOnly = false
    @State private var adding = false

    private var service: VaultService { VaultService(client: client) }
    /// Full access: associate producers and up (`requireFullVaultActor`).
    private var fullAccess: Bool { session.user?.isProducer == true }

    var body: some View {
        Group {
            if notAvailable {
                NotAvailableView(message: "Passwords are for producers, and for people a producer shared a login with.")
            } else {
                LoadableView(state, retry: { Task { await load() } }) { entries in
                    list(entries)
                }
            }
        }
        .brandBackground()
        .navigationTitle("Passwords")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Name, website or username")
        .toolbar {
            if fullAccess {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add password", systemImage: "plus") { adding = true }
                        .disabled(state.value == nil)
                }
            }
        }
        .sheet(isPresented: $adding) {
            VaultEditorSheet(entry: nil, service: service) { Task { await load() } }
        }
        .task { await load() }
    }

    private func list(_ entries: [VaultEntry]) -> some View {
        let shown = VaultSearch.filter(entries, query, sharedOnly: sharedOnly)
        let canFilter = entries.contains(where: \.canShare)
        return List {
            if canFilter {
                HStack(spacing: 8) {
                    Chip(title: "All \(entries.count)", selected: !sharedOnly) { sharedOnly = false }
                    Chip(title: "Shared \(entries.filter { $0.sharedWith > 0 }.count)", selected: sharedOnly) { sharedOnly = true }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            Section {
                if shown.isEmpty {
                    Text(entries.isEmpty ? "No logins yet." : "No logins match.").foregroundStyle(Brand.secondary)
                }
                ForEach(shown) { entry in
                    NavigationLink(value: Route.admin(.vaultEntry(id: entry.id))) { VaultRow(entry: entry) }
                }
            } footer: {
                Text(fullAccess ? "Every password, notes and 2FA view is logged with your name."
                     : "These logins were shared with you. Every view is logged with your name.")
                    .font(.small)
            }
        }
        .toolsList()
        .refreshable { await load() }
    }

    private func load() async {
        await ToolLoad.run($state, notAvailable: $notAvailable) { try await service.entries() }
    }
}

private struct VaultRow: View {
    let entry: VaultEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(String(entry.name.prefix(1)).uppercased())
                .font(.lexend(15, .semibold))
                .foregroundStyle(Brand.green)
                .frame(width: 36, height: 36)
                .background(Brand.greenTint, in: RoundedRectangle(cornerRadius: Brand.radius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).foregroundStyle(Brand.foreground)
                if let detail = entry.username ?? entry.host {
                    Text(detail).font(.small).foregroundStyle(Brand.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if entry.hasTotp { StatusTag(text: "2FA") }
            if entry.sharedWith > 0 { StatusTag(text: "Shared", tone: .success) }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
