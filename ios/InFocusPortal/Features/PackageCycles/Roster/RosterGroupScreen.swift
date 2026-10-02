import SwiftUI

/// One group: topic, members, assigned producer, stage progress and notes. Chart editors
/// change them here; stages themselves are reviewed in Groups.
struct RosterGroupScreen: View {
    let rowId: String
    let cycle: Int

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var store: RosterStore?
    @State private var sheet: RosterGroupSheet?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let store {
                LoadableView(store.state, retry: { Task { await store.load() } }) { roster in
                    if let row = roster.rows.first(where: { $0.id == rowId }) {
                        content(row, roster, store: store)
                    } else {
                        EmptyStateView(title: "Group not found",
                                       message: "It was moved to another cycle or deleted.")
                    }
                }
                .rosterAlerts(store)
                .sheet(item: $sheet) { sheet in sheetView(sheet, store: store) }
            } else {
                ScrollView { SkeletonList().padding(Brand.gutter) }
            }
        }
        .brandBackground()
        .navigationTitle("Group")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let store = self.store ?? RosterStore(service: .resolve(client), cycle: cycle)
            self.store = store
            await store.load()
            if store.canEdit { await store.loadPeople() }
        }
    }

    private func content(_ row: RosterRow, _ roster: RosterPayload, store: RosterStore) -> some View {
        let editable = roster.canEdit && !store.saving
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Nameplate(eyebrow: "Cycle \(cycle) group", title: row.topic.isEmpty ? "No topic yet" : row.topic,
                          subtitle: RosterLogic.assignedLabel(row, producers: roster.producers, executives: roster.executives) ?? "Unassigned") {
                    if roster.canEdit {
                        Button("Edit") { sheet = .topic }
                            .font(.lexend(15, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Brand.green)
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(!editable)
                            .accessibilityLabel("Edit topic")
                    }
                }
                GroupMembersSection(row: row, roster: roster, editable: editable,
                                    add: { sheet = .members },
                                    remove: { id in Task { await store.setMembers(rowId, row.memberUserIds.filter { $0 != id }) } })
                GroupProducerSection(label: RosterLogic.assignedLabel(row, producers: roster.producers, executives: roster.executives),
                                     editable: editable && roster.canAssignProducer, change: { sheet = .producer })
                GroupStagesSection(row: row) { router.push(.work(.group(rowId: rowId, stage: nil))) }
                GroupNotesSection(row: row, editable: editable) { sheet = .notes }
                if roster.canEdit {
                    GroupActionsSection(cycle: cycle, cycles: roster.cycles.map(\.cycleNumber), busy: store.saving,
                                        move: { target in Task { if await store.move(rowId, to: target) { dismiss() } } },
                                        delete: { confirmDelete = true })
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await store.load() }
        .confirmationDialog("Delete this group?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete group", role: .destructive) {
                Task { if await store.delete(rowId) { dismiss() } }
            }
        } message: {
            Text("Its members leave the roster for Cycle \(cycle). This can't be undone.")
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: RosterGroupSheet, store: RosterStore) -> some View {
        if let row = store.row(rowId), let roster = store.roster {
            switch sheet {
            case .topic:
                GroupTopicSheet(topic: row.topic) { await store.setTopic(rowId, $0) }
            case .notes:
                GroupNotesSheet(interviews: row.interviews, ideas: row.ideas, notes: row.notes) {
                    await store.setNotes(rowId, interviews: $0, ideas: $1, notes: $2)
                }
            case .members:
                MemberPickerSheet(people: store.people, memberIds: row.memberUserIds,
                                  previous: roster.previousTeammatesByUser) { await store.setMembers(rowId, $0) }
            case .producer:
                ProducerPickerSheet(options: RosterLogic.assignable(producers: roster.producers, executives: roster.executives),
                                    selected: row.assignedExecutiveUserId ?? row.assignedProducerUserId) {
                    await store.assign(rowId, to: $0)
                }
            }
        }
    }
}

enum RosterGroupSheet: String, Identifiable {
    case topic, notes, members, producer
    var id: String { rawValue }
}
