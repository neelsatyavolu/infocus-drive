import SwiftUI

/// "Acting as" banner: who the app shows while View as is on, and the way out.
struct ViewAsActiveSection: View {
    let status: ViewAsStatus
    let stopping: Bool
    let stop: () -> Void

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(Brand.green)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Viewing as", color: Brand.muted, size: 11)
                    Text(status.actingAsLabel).font(.h3).foregroundStyle(Brand.foreground)
                    Text("The app shows what they see. Changes you make are saved as \(status.realUser?.label ?? "you").")
                        .font(.small).foregroundStyle(Brand.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            Button(stopping ? "Stopping…" : "Stop viewing as") { stop() }
                .buttonStyle(.brandPrimary)
                .disabled(stopping)
                .listRowBackground(Color.clear)
        }
    }
}

/// The banner for screens outside Admin (Settings). The screen keeps the status (load it
/// with `ViewAsBanner.load(client:user:)`); the banner shows only while View as is on, so
/// the person can always get back to their own account.
struct ViewAsBanner: View {
    @Binding var status: ViewAsStatus?
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(BadgeCenter.self) private var badges
    @State private var stopping = false
    @State private var actionError: String?

    var body: some View {
        if let current = status, current.active {
            ViewAsActiveSection(status: current, stopping: stopping) { Task { await stop() } }
                .actionErrorAlert($actionError)
        }
    }

    /// Best effort: nil (no banner) for the sample account or when the status can't load.
    static func load(client: PortalClient, user: PortalUser?) async -> ViewAsStatus? {
        guard user?.sampleOnly == false else { return nil }
        return try? await AdminService(client: client).viewAsStatus()
    }

    private func stop() async {
        stopping = true
        defer { stopping = false }
        do {
            try await ViewAsSwitch.apply(nil, client: client, session: session, router: router, badges: badges)
            status = nil
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }
}
