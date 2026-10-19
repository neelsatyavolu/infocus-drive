import SwiftUI

/// Home's workspaces: the most recent projects, and the full list. It's also all the
/// App Review sample account sees of the class: its own sample workspace.
struct WorkspacesHomeSection: View {
    let workspaces: [WorkspaceSummary]
    @Environment(Router.self) private var router

    static let shown = 3

    private var recent: [ProjectSummary] {
        Array(workspaces.flatMap(\.projects).sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.shown))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Projects", actionTitle: "All workspaces") { router.push(.review(.workspaces)) }
            if recent.isEmpty {
                Text("No projects yet.").font(.small).foregroundStyle(Brand.muted)
            }
            ForEach(recent) { project in
                Button { router.push(.review(.project(id: project.id))) } label: {
                    HStack {
                        ProjectRowLabel(project: project)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(Brand.muted).accessibilityHidden(true)
                    }
                    .card(padding: 12)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
