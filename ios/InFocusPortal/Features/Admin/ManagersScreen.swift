import SwiftUI

/// More → Managers, the native `/managers`: each manager area and the tool it opens.
/// Producers also see who's appointed (each tool's own Managers list appoints them).
/// The Portal has no API that says which areas a student is appointed to, so every
/// tool is listed and the tool itself says if it isn't available.
struct ManagersScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @State private var rosters: [ManagerArea: ManagerRoster] = [:]

    private var isProducer: Bool { session.user?.isProducer == true }

    var body: some View {
        List {
            Section {
                Nameplate(eyebrow: "Managers", title: "Manager tools",
                          subtitle: isProducer ? "You can open every tool and appoint managers." : "Producers appoint managers from each tool.")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("Areas") {
                ForEach(ManagerArea.allCases) { area in
                    NavigationLink(value: area.route) {
                        AreaRow(area: area, roster: isProducer ? rosters[area] : nil)
                    }
                }
            }
            Section("How manager roles work") {
                HowRow(systemImage: "person.badge.plus", title: "Producers appoint",
                       text: "Each tool has a Managers list. A producer adds you there.")
                HowRow(systemImage: "key", title: "Your tool unlocks",
                       text: "Once you're on a list, you can open that tool from here right away.")
                HowRow(systemImage: "checkmark.shield", title: "Only that tool",
                       text: "A manager role never grants producer access. Removal locks it again.")
            }
        }
        .toolsList()
        .navigationTitle("Managers")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRosters() }
        .refreshable { await loadRosters() }
    }

    /// Best effort: a roster that fails to load just shows no names.
    private func loadRosters() async {
        guard isProducer else { return }
        let service = ManagersService(client: client)
        await withTaskGroup(of: (ManagerArea, ManagerRoster?).self) { group in
            for area in ManagerArea.allCases {
                group.addTask { (area, try? await service.roster(area)) }
            }
            for await (area, roster) in group {
                if let roster { rosters[area] = roster }
            }
        }
    }
}

private struct AreaRow: View {
    let area: ManagerArea
    let roster: ManagerRoster?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: area.systemImage)
                .foregroundStyle(Brand.green)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(area.title, color: Brand.muted, size: 11)
                Text(area.tool).font(.h3).foregroundStyle(Brand.foreground)
                Text(area.summary).font(.small).foregroundStyle(Brand.secondary)
                if let roster {
                    Text("Managers: \(roster.namesLine)").font(.small).foregroundStyle(Brand.muted)
                }
                Text(area.access).font(.small).foregroundStyle(Brand.muted)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct HowRow: View {
    let systemImage: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(Brand.green).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.h3).foregroundStyle(Brand.foreground)
                Text(text).font(.small).foregroundStyle(Brand.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Managers → Social media: the Instagram Post Maker (it draws in the browser, so it
/// opens the Portal page) and, for producers, the social media manager roster.
struct SocialMediaManagersScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session
    @State private var state: Loadable<ManagerRoster> = .idle
    @State private var adding = false
    @State private var busyId: String?
    @State private var removing: ManagerRoster.Manager?
    @State private var actionError: String?

    private var service: ManagersService { ManagersService(client: client) }
    private var isProducer: Bool { session.user?.isProducer == true }

    var body: some View {
        List {
            Section {
                Nameplate(eyebrow: "Social media", title: "Instagram Post Maker",
                          subtitle: "On-brand stories from your photos, as PNGs.")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                Button("Open the Post Maker") {
                    router.openPortal("managers/social-media", title: "Instagram Post Maker")
                }
                .buttonStyle(.brandPrimary)
                .listRowBackground(Color.clear)
            } footer: {
                Text("Photos are processed on this iPhone and never uploaded.")
            }
            if isProducer {
                Section {
                    switch state {
                    case .idle, .loading:
                        ProgressView().frame(maxWidth: .infinity)
                    case .failed(let message):
                        Text(message).font(.small).foregroundStyle(Brand.danger)
                    case .loaded(let roster):
                        if roster.managers.isEmpty {
                            Text("No social media managers yet.").foregroundStyle(Brand.secondary)
                        }
                        ForEach(roster.managers) { manager in
                            PersonLine(title: manager.label, detail: manager.email, busy: busyId == manager.userId)
                                .swipeActions {
                                    Button("Remove", role: .destructive) { removing = manager }
                                }
                        }
                        Button("Add a manager", systemImage: "person.badge.plus") { adding = true }
                    }
                } header: {
                    Text("Social media managers")
                } footer: {
                    Text("They can use the Post Maker. Producers manage this list.")
                }
            }
        }
        .toolsList()
        .navigationTitle("Social media")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) {
            if let roster = state.value {
                CandidatePicker(candidates: roster.candidates.filter { candidate in
                    !roster.managers.contains { $0.userId == candidate.id }
                }) { candidate in
                    Task { await change(candidate.id) { try await service.addSocialManager(userId: candidate.id) } }
                }
            }
        }
        .confirmationDialog("Remove \(removing?.label ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let manager = removing {
                    Task { await change(manager.userId) { try await service.removeSocialManager(userId: manager.userId) } }
                }
            }
        } message: {
            Text("They lose access to the Post Maker.")
        }
        .actionErrorAlert($actionError)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard isProducer else { return }
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await service.roster(.socialMedia))
        } catch {
            if state.value == nil { state = .failed(Loadable<ManagerRoster>.message(for: error)) }
        }
    }

    private func change(_ userId: String, _ action: () async throws -> Void) async {
        busyId = userId
        defer { busyId = nil }
        do {
            try await action()
            await load()
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }
}

/// Search the class and pick someone to appoint.
private struct CandidatePicker: View {
    let candidates: [ManagerRoster.Candidate]
    let pick: (ManagerRoster.Candidate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [ManagerRoster.Candidate] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return candidates }
        return candidates.filter { [$0.name, $0.email].contains { $0?.lowercased().contains(needle) == true } }
    }

    var body: some View {
        NavigationStack {
            List(matches) { candidate in
                Button {
                    pick(candidate)
                    dismiss()
                } label: {
                    PersonLine(title: candidate.label, detail: candidate.email)
                }
            }
            .toolsList()
            .searchable(text: $query, prompt: "Name or email")
            .navigationTitle("Add a social media manager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
