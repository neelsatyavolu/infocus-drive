import SwiftUI

/// Execs grant an extension to a package group (or some of its members) without a request.
/// It counts as the first approval; one more exec must approve.
struct GrantExtensionSheet: View {
    let service: GradesService
    let initialCycle: Int
    let cycleNumbers: [Int]
    let onGranted: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cycle: Int
    @State private var groups: Loadable<[GrantGroup]> = .idle
    @State private var groupId = ""
    @State private var selected: Set<String> = []
    @State private var days: Double = 2
    @State private var reason = ""
    @State private var saving = false
    @State private var errorMessage: String?

    init(service: GradesService, initialCycle: Int, cycleNumbers: [Int], onGranted: @escaping () async -> Void) {
        self.service = service
        self.initialCycle = initialCycle
        self.cycleNumbers = cycleNumbers
        self.onGranted = onGranted
        _cycle = State(initialValue: initialCycle)
    }

    private var group: GrantGroup? { groups.value?.first { $0.id == groupId } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Cycle", selection: $cycle) {
                        ForEach(cycleNumbers.contains(cycle) ? cycleNumbers : cycleNumbers + [cycle], id: \.self) {
                            Text("Cycle \($0)").tag($0)
                        }
                    }
                    ExtensionDaysField(days: $days)
                } footer: {
                    Text("No group agreement needed. One more executive producer must approve, then every chosen student gets an email.")
                }
                Section("Group") { groupPicker }
                if let group {
                    Section("Who gets it") {
                        ForEach(group.members, id: \.userId) { member in
                            Toggle(member.label, isOn: Binding(
                                get: { selected.contains(member.userId) },
                                set: { on in if on { selected.insert(member.userId) } else { selected.remove(member.userId) } }
                            ))
                            .tint(Brand.fill)
                        }
                    }
                }
                Section("Reason (optional)") {
                    TextField("Reason", text: $reason, axis: .vertical).lineLimit(2...6)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(Brand.danger)
                    }
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Grant an extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Grant") { Task { await grant() } }
                        .disabled(saving || group == nil || selected.isEmpty || !ExtensionRequest.isValidDays(days))
                }
            }
            .interactiveDismissDisabled(saving)
            .task(id: cycle) { await loadGroups() }
        }
    }

    @ViewBuilder private var groupPicker: some View {
        switch groups {
        case .idle, .loading:
            HStack { Text("Loading groups…").foregroundStyle(Brand.muted); Spacer(); ProgressView() }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Brand.danger)
        case .loaded(let list) where list.isEmpty:
            Text("No groups in this cycle").foregroundStyle(Brand.muted)
        case .loaded(let list):
            Picker("Group", selection: $groupId) {
                Text("Pick a group").tag("")
                ForEach(list) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.navigationLink)
            .onChange(of: groupId) { _, id in
                selected = Set(list.first { $0.id == id }?.members.map(\.userId) ?? [])
            }
        }
    }

    /// A new cycle starts over: its groups load and nothing is picked.
    private func loadGroups() async {
        groups = .loading
        groupId = ""
        selected = []
        do {
            groups = .loaded(try await service.grantGroups(cycle: cycle))
        } catch {
            groups = .failed(Loadable<[GrantGroup]>.message(for: error))
        }
    }

    private func grant() async {
        guard let group else { return }
        saving = true
        errorMessage = nil
        do {
            try await service.grant(NewExtensionGrant(progressRowId: group.id, days: ExtensionRequest.roundDays(days),
                                                      grantedUserIds: group.members.map(\.userId).filter(selected.contains),
                                                      reason: reason))
            await onGranted()
            dismiss()
        } catch {
            errorMessage = Loadable<[GrantGroup]>.message(for: error)
        }
        saving = false
    }
}
