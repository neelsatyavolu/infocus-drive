import SwiftUI

/// The Package Cycle roster: a cycle's groups with their topic, members and assigned
/// producer. Executives, the adviser and the super admin edit it; associates view it.
struct RosterView: View {
    @Bindable var store: RosterStore
    @Environment(Router.self) private var router

    var body: some View {
        LoadableView(store.state, retry: { Task { await store.load() } }) { roster in
            content(roster)
        }
        .rosterAlerts(store)
    }

    private func content(_ roster: RosterPayload) -> some View {
        let stats = RosterLogic.stats(roster.rows)
        return VStack(alignment: .leading, spacing: 16) {
            Nameplate(eyebrow: "Package Cycle", title: "Cycle \(roster.activeCycleNumber)",
                      subtitle: "\(stats.total) groups · \(stats.withMembers) with members · \(stats.withAssigned) assigned")
            RosterCyclePicker(cycles: roster.cycles.map(\.cycleNumber), selected: roster.activeCycleNumber) { number in
                Task { await store.load(cycle: number) }
            }
            if !roster.canEdit {
                Label("View only. Executive producers edit the roster.", systemImage: "eye")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
            }
            if let notice = store.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.small)
                    .foregroundStyle(Brand.green)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.5))
                        store.notice = nil
                    }
            }
            if roster.rows.isEmpty {
                EmptyStateView(title: "No groups yet", message: roster.canEdit
                               ? "Add a group to start this cycle's roster." : "Groups appear here once they're added.",
                               actionTitle: roster.canEdit ? "Add group" : nil,
                               action: roster.canEdit ? { addGroup() } : nil)
                    .card()
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(roster.rows) { row in
                        NavigationLink(value: Route.packageCycles(.group(rowId: row.id, cycle: roster.activeCycleNumber))) {
                            RosterGroupCard(row: row,
                                      assigned: RosterLogic.assignedLabel(row, producers: roster.producers, executives: roster.executives),
                                      repeated: repeatedNames(row, roster))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if roster.canEdit {
                    Button { addGroup() } label: {
                        Label("Add group", systemImage: "plus")
                    }
                    .buttonStyle(.brandSecondary)
                    .disabled(store.saving)
                }
            }
        }
    }

    private func repeatedNames(_ row: RosterRow, _ roster: RosterPayload) -> [String] {
        let pairs = RosterLogic.repeatedPairs(row.memberUserIds, previous: roster.previousTeammatesByUser)
        let names = Dictionary(row.members.map { ($0.userId, $0.name) }, uniquingKeysWith: { first, _ in first })
        return pairs.map(\.userId).compactMap { names[$0] }
    }

    private func addGroup() {
        Task {
            if let id = await store.addGroup(), let cycle = store.cycle {
                router.push(.packageCycles(.group(rowId: id, cycle: cycle)))
            }
        }
    }
}

/// Cycle chips (1…N), the selected one filled.
struct RosterCyclePicker: View {
    let cycles: [Int]
    let selected: Int
    let pick: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(cycles, id: \.self) { number in
                    Chip(title: "Cycle \(number)", selected: number == selected) { pick(number) }
                        .accessibilityLabel("Cycle \(number)")
                }
            }
        }
    }
}

extension View {
    /// Shows a roster store's save errors.
    func rosterAlerts(_ store: RosterStore) -> some View {
        alert("Couldn't save", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}
