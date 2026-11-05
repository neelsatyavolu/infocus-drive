import SwiftUI

/// The student's cycle: their package and each stage in order with its status,
/// unread feedback, and whether it's unlocked yet.
struct PackagesScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @State private var state: Loadable<StudentGates> = .idle
    @State private var switching = false
    @State private var switchError: String?

    var body: some View {
        ScrollView {
            LoadableView(state, retry: { Task { await load() } }) { gates in
                VStack(alignment: .leading, spacing: 16) {
                    Nameplate(eyebrow: "Cycle \(gates.cycleNumber)", title: "Your package",
                              subtitle: gates.hasRow ? "Work through each stage in order." : nil)
                    if let choices = gates.cycleChoices, choices.count > 1 {
                        cycleSwitch(choices, current: gates.cycleNumber)
                    }
                    if gates.hasRow {
                        ForEach(StudentStage.allCases.filter { $0 != .information }) { stage in
                            StageRowLink(stage: stage, gates: gates)
                        }
                    } else {
                        EmptyStateView(title: "Not on a package yet",
                                       message: "When your group is on the Package Cycle roster, your stages show up here.")
                            .card()
                    }
                    HStack(spacing: 12) {
                        NavigationLink(value: Route.work(.studentStage(.information))) {
                            Label("Cycle guide", systemImage: "book").font(.lexend(15, .medium))
                        }
                        .buttonStyle(.brandSecondary)
                        if session.user?.isProducer != true {
                            NavigationLink(value: Route.grades(.extensions)) {
                                Label("Extension requests", systemImage: "clock.arrow.circlepath").font(.lexend(15, .medium))
                            }
                            .buttonStyle(.brandSecondary)
                        }
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await load() }
        .brandBackground()
        .navigationTitle("Packages")
        // Again on every visit: a stage page marks its feedback read and may change a status.
        .task { await load() }
    }

    /// "Cycle 2 | Cycle 3" for a student still owing the previous Final Cut while on the new roster.
    private func cycleSwitch(_ choices: [Int], current: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Cycle to work on", color: Brand.muted)
            Picker("Cycle to work on", selection: Binding(get: { current }, set: { pick in
                Task { await switchCycle(to: pick) }
            })) {
                ForEach(choices, id: \.self) { Text("Cycle \($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(switching)
            Text("Your Cycle \(choices[0]) Final Cut isn't in yet. Pick the cycle your stages show. You can switch back anytime.")
                .font(.small).foregroundStyle(Brand.muted).fixedSize(horizontal: false, vertical: true)
            if let switchError {
                Label(switchError, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
            }
        }
        .card()
    }

    /// Saves the pick (the web's cycle cookie), then reloads so the stages follow it.
    private func switchCycle(to cycle: Int) async {
        guard !switching, cycle != state.value?.cycleNumber else { return }
        switching = true
        switchError = nil
        defer { switching = false }
        await StudentCycleChoice.choose(cycle, portal: client.portal)
        await load()
        await session.load(using: client)
        if let shown = state.value?.cycleNumber, shown != cycle {
            switchError = "Cycle \(cycle) isn't open to you right now."
        }
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
                    StatusTag(text: StageGuide.label(status, remainingExecutiveSignoffs: gates.remainingExecutiveSignoffs), tone: status.tone)
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
