import SwiftUI

/// The student's cycle: their package and each stage in order with its status,
/// unread feedback, and whether it's unlocked yet.
struct PackagesScreen: View {
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<StudentGates> = .idle

    var body: some View {
        ScrollView {
            LoadableView(state, retry: { Task { await load() } }) { gates in
                VStack(alignment: .leading, spacing: 16) {
                    Nameplate(eyebrow: "Cycle \(gates.cycleNumber)", title: "Your package",
                              subtitle: gates.hasRow ? "Work through each stage in order." : nil)
                    if gates.hasRow {
                        ForEach(StudentStage.allCases) { stage in
                            StageRowLink(stage: stage, gates: gates)
                        }
                    } else {
                        EmptyStateView(title: "Not on a package yet",
                                       message: "When your group is on the Package Cycle roster, your stages show up here.")
                            .card()
                        NavigationLink(value: Route.work(.studentStage(.information))) {
                            Label("Cycle information", systemImage: "info.circle").font(.lexend(15, .medium))
                        }
                        .buttonStyle(.brandSecondary)
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await load() }
        .brandBackground()
        .navigationTitle("Packages")
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await workAPI(client).gates())
        } catch {
            if state.value == nil { state = .failed(Loadable<StudentGates>.message(for: error)) }
        }
    }
}

private struct StageRowLink: View {
    let stage: StudentStage
    let gates: StudentGates

    var body: some View {
        let unlocked = gates.isUnlocked(stage)
        let unread = gates.unread[stage.rawValue] ?? 0
        NavigationLink(value: Route.work(.studentStage(stage))) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(unlocked ? Brand.green : Brand.muted)
                    .frame(width: 40, height: 40)
                    .background(unlocked ? Brand.greenTint : Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(stage.title).font(.h3).foregroundStyle(unlocked ? Brand.foreground : Brand.muted)
                    if unread > 0 {
                        Text("\(unread) new comment\(unread == 1 ? "" : "s")").font(.small).foregroundStyle(Brand.warning)
                    }
                }
                Spacer(minLength: 0)
                if let status = gates.status(stage) {
                    StatusTag(text: status.label, tone: status.tone)
                }
                Image(systemName: unlocked ? "chevron.right" : "lock.fill").foregroundStyle(Brand.muted).accessibilityHidden(true)
            }
            .card(padding: 12)
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
        .accessibilityValue(unlocked ? gates.status(stage)?.label ?? "" : "Locked")
    }

    private var icon: String {
        switch stage {
        case .information: "info.circle"
        case .brainstorming: "lightbulb"
        case .aRoll: "video"
        case .initialCut: "film"
        case .finalCut: "checkmark.seal"
        }
    }
}
