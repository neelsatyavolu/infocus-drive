import SwiftUI

/// Every workspace this person can see and its projects. Producers can add and delete projects.
struct WorkspacesScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<[WorkspaceSummary]> = .idle
    @State private var newProjectIn: WorkspaceSummary?
    @State private var newProjectName = ""
    @State private var deleting: ProjectSummary?
    @State private var actionError: String?

    private var api: ReviewAPI { .resolve(client) }
    private var canManage: Bool { session.user?.isProducer == true }

    var body: some View {
        LoadableView(state, retry: { Task { await load() } }) { workspaces in
            if workspaces.isEmpty {
                EmptyStateView(title: "No workspaces", message: "Workspaces you're added to show up here.")
            } else {
                list(workspaces)
            }
        }
        .brandBackground()
        .navigationTitle("Workspaces")
        .task { if state.value == nil { await load() } }
        .alert("New project", isPresented: Binding(get: { newProjectIn != nil }, set: { if !$0 { newProjectIn = nil } })) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { if let workspace = newProjectIn { Task { await create(in: workspace) } } }
        } message: {
            Text("2 to 120 characters.")
        }
        .confirmationDialog("Delete this project?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { project in
            Button("Delete \(project.name)", role: .destructive) { Task { await delete(project) } }
        } message: { _ in
            Text("Every video, image and comment in it is deleted for good.")
        }
        .alert("Couldn't finish that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func list(_ workspaces: [WorkspaceSummary]) -> some View {
        List {
            ForEach(workspaces) { workspace in
                Section {
                    if workspace.projects.isEmpty {
                        Text("No projects yet").font(.small).foregroundStyle(Brand.muted)
                    }
                    ForEach(workspace.projects) { project in
                        NavigationLink(value: Route.review(.project(id: project.id))) {
                            ProjectRowLabel(project: project)
                        }
                        .swipeActions {
                            if canManage {
                                Button("Delete", role: .destructive) { deleting = project }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(workspace.name)
                        Spacer()
                        if canManage {
                            Button {
                                newProjectName = ""
                                newProjectIn = workspace
                            } label: {
                                Label("New project", systemImage: "plus")
                            }
                            .font(.lexend(13, .medium))
                            .foregroundStyle(Brand.green)
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
        }
        .font(.bodyText)
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.workspaces())
        } catch PortalError.forbidden {
            state = .loaded([])
        } catch {
            if state.value == nil { state = .failed(Loadable<[WorkspaceSummary]>.message(for: error)) }
        }
    }

    private func create(in workspace: WorkspaceSummary) async {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...120).contains(name.count) else {
            actionError = "Project names are 2 to 120 characters."
            return
        }
        do {
            let project = try await api.createProject(workspace.id, name)
            await load()
            router.push(.review(.project(id: project.id)))
        } catch {
            actionError = Loadable<Void>.message(for: error)
        }
    }

    private func delete(_ project: ProjectSummary) async {
        do {
            try await api.deleteProject(project.id)
            await load()
        } catch {
            actionError = Loadable<Void>.message(for: error)
        }
    }
}

/// A project's name, item count and when it last changed.
struct ProjectRowLabel: View {
    let project: ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name).font(.lexend(16, .medium)).foregroundStyle(Brand.foreground)
            HStack(spacing: 6) {
                Text("\(project.mediaCount) \(project.mediaCount == 1 ? "item" : "items")").font(.mono(12))
                Text("·")
                Text(project.updatedAt, format: .relative(presentation: .named))
            }
            .font(.small)
            .foregroundStyle(Brand.muted)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
