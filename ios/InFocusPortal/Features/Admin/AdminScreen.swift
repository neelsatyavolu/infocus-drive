import SwiftUI

/// More → Admin (executive producers and up), the native `/admin`: totals, access
/// requests, people, the producer team, cycles per semester, and for the super
/// admin backups and View as. Calendar days, school years, integrations (Google
/// sign-in) and the danger zone stay on the Portal page.
struct AdminScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var state: Loadable<AdminOverview> = .idle
    @State private var notAvailable = false
    @State private var actionError: String?
    @State private var savingCycles = false

    private var service: AdminService { AdminService(client: client) }

    var body: some View {
        Group {
            if notAvailable {
                NotAvailableView(message: "Admin is for executive producers, the adviser and the super admin.")
            } else {
                LoadableView(state, retry: { Task { await load() } }) { overview in
                    content(overview)
                }
            }
        }
        .brandBackground()
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
        .actionErrorAlert($actionError)
        .task { await load() }
    }

    private func content(_ overview: AdminOverview) -> some View {
        List {
            Section {
                Nameplate(eyebrow: "Admin", title: "Dashboard",
                          subtitle: overview.access.permissions.canManagePlatformRoles ? "Super admin" : "Executive producer")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                if let stats = overview.stats {
                    TotalsGrid(stats: stats)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
            Section("People") {
                NavigationLink(value: Route.admin(.accessRequests)) {
                    Label("Access requests", systemImage: "person.badge.clock")
                }
                .badge(overview.pendingRequests)
                NavigationLink(value: Route.admin(.people)) { Label("People", systemImage: "person.2") }
                NavigationLink(value: Route.admin(.producerTeam)) { Label("Producer team", systemImage: "person.3.sequence") }
            }
            Section {
                if let settings = overview.settings {
                    CyclesStepper(settings: settings, saving: savingCycles) { count in
                        Task { await saveCycles(count) }
                    }
                }
                Button { router.openPortal("admin#school-year", title: "School year") } label: {
                    Label("Calendar days, school years and settings", systemImage: "calendar")
                        .foregroundStyle(Brand.foreground)
                }
            } header: {
                Text("School year")
            } footer: {
                Text("Calendar days, school years and class settings open on the Portal page.")
            }
            if overview.access.permissions.canManagePlatformRoles {
                Section {
                    NavigationLink(value: Route.admin(.backups)) { Label("Backups", systemImage: "externaldrive.badge.timemachine") }
                    NavigationLink(value: Route.admin(.viewAs)) { Label("View as", systemImage: "person.crop.circle.badge.questionmark") }
                    Button { router.openPortal("admin#system", title: "System") } label: {
                        Label("Integrations and danger zone", systemImage: "gearshape.2")
                            .foregroundStyle(Brand.foreground)
                    }
                } header: {
                    Text("System")
                } footer: {
                    Text("Connecting YouTube or Google Calendar and resetting cycles happen on the Portal page.")
                }
            }
        }
        .toolsList()
        .refreshable { await load() }
    }

    private func load() async {
        await ToolLoad.run($state, notAvailable: $notAvailable) {
            let access = try await service.access()
            guard access.permissions.canManageAllowedEmails else { throw PortalError.forbidden("Forbidden") }
            async let stats = try? service.stats()
            async let requests = try? service.accessRequests()
            async let settings = try? service.programSettings()
            return AdminOverview(access: access, stats: await stats,
                                 pendingRequests: (await requests)?.filter(\.isPending).count ?? 0,
                                 settings: await settings)
        }
    }

    private func saveCycles(_ count: Int) async {
        savingCycles = true
        defer { savingCycles = false }
        do {
            try await service.setCyclesPerSemester(count)
            await load()
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }
}

/// What the dashboard shows. Totals, requests and settings are best effort.
struct AdminOverview: Sendable {
    let access: PlatformAccess
    let stats: PlatformStats?
    let pendingRequests: Int
    let settings: ProgramSettings?
}

private struct TotalsGrid: View {
    let stats: PlatformStats

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            StatTile(label: "People", value: "\(stats.totals.users)")
            StatTile(label: "Projects", value: "\(stats.totals.projects)")
            StatTile(label: "Media", value: "\(stats.totals.activeMedia)")
            StatTile(label: "Comments", value: "\(stats.totals.comments)")
            StatTile(label: "Share links", value: "\(stats.totals.activeShareLinks)")
            StatTile(label: stats.storage.isEstimated ? "Storage (est.)" : "Storage",
                     value: AdminFormat.storage(stats.storage.estimatedBytes))
        }
    }
}

/// Package cycles per semester (executive producers change it; it reshapes every grade).
private struct CyclesStepper: View {
    let settings: ProgramSettings
    let saving: Bool
    let save: (Int) -> Void
    @State private var pending: Int?
    @State private var confirming = false

    var body: some View {
        let shown = pending ?? settings.cyclesPerSemester
        Stepper(value: Binding(get: { shown }, set: { pending = $0; confirming = true }), in: ProgramSettings.range) {
            HStack {
                Text("Cycles per semester")
                Spacer()
                if saving { ProgressView() } else {
                    Text("\(shown)").font(.mono(16, .medium)).monospacedDigit().foregroundStyle(Brand.secondary)
                }
            }
        }
        .disabled(settings.canEdit != true || saving)
        .frame(minHeight: 44)
        .onChange(of: confirming) { _, open in if !open { pending = nil } }
        .confirmationDialog("Change cycles per semester to \(pending ?? 0)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Change") { if let pending { save(pending) }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("This changes the shape of every grade for the semester.")
        }
    }
}
