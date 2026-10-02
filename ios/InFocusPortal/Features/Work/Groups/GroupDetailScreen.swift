import SwiftUI

/// A package's row on Groups, found from its id alone (deep links carry only
/// the id): the stage view says which cycle it's in, that cycle's roster has it.
enum GroupLookup {
    struct Found: Sendable { let row: GroupRow; let cycle: Int? }

    static func find(_ rowId: String, api: WorkAPI) async throws -> Found {
        let stage = try await api.stage(GroupStage.aRoll.rawValue, rowId, nil)
        let cycle = stage.row?.cycleNumber
        let payload = try await api.groups(cycle)
        guard let row = payload.rows.first(where: { $0.id == rowId }) else {
            throw PortalError.notFound
        }
        return Found(row: row, cycle: cycle)
    }
}

/// One group: its package, people, status, and each stage to review.
struct GroupDetailScreen: View {
    let rowId: String

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var state: Loadable<GroupRow> = .idle

    var body: some View {
        ScrollView {
            LoadableView(state, retry: { Task { await load() } }) { row in
                VStack(alignment: .leading, spacing: 20) {
                    let status = GroupTileStatus.of(row)
                    Nameplate(eyebrow: row.groupType?.isEmpty == false ? row.groupType! : "Package", title: row.topic,
                              subtitle: row.memberNames.isEmpty ? nil : row.memberNames)
                    StatusTag(text: status.label, tone: status.tone)
                    people(row)
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Stages")
                        let current = GroupStage.current(for: row)
                        ForEach(GroupStage.allCases) { stage in
                            NavigationLink(value: Route.work(.group(rowId: row.id, stage: stage.rawValue))) {
                                HStack(spacing: 12) {
                                    Image(systemName: stage.isDone(for: row) ? "checkmark.circle.fill" : stage == current ? "circle.inset.filled" : "circle")
                                        .foregroundStyle(stage.isDone(for: row) || stage == current ? Brand.green : Brand.muted)
                                        .font(.system(size: 18))
                                        .accessibilityHidden(true)
                                    Text(stage.title).font(.bodyText).foregroundStyle(Brand.foreground)
                                    Spacer()
                                    if stage == current { StatusTag(text: "Now", tone: .warning) }
                                    Image(systemName: "chevron.right").foregroundStyle(Brand.muted).accessibilityHidden(true)
                                }
                                .frame(minHeight: 44)
                                .card(padding: 12)
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(stage.isDone(for: row) ? "Done" : stage == current ? "Current stage" : "")
                        }
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await load() }
        .brandBackground()
        .navigationTitle("Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { router.openPortal("groups/\(rowId)", title: "Group") } label: { Image(systemName: "safari") }
                    .accessibilityLabel("Open on the Portal")
                    .hiddenInSampleApp()
            }
        }
        .task { if state.value == nil { await load() } }
    }

    private func people(_ row: GroupRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let producer = row.assignedProducer {
                Label("Producer: \(producer.displayName)", systemImage: "person.crop.circle")
            }
            if let executive = row.assignedExecutiveProducer {
                Label("Executive: \(executive.displayName)", systemImage: "person.crop.circle.badge.checkmark")
            }
            if let days = row.extensionDays, days > 0 {
                Label("Extension: \(SnapshotCard.number(days)) day\(days == 1 ? "" : "s")", systemImage: "calendar.badge.clock")
            }
        }
        .font(.small)
        .foregroundStyle(Brand.secondary)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await GroupLookup.find(rowId, api: workAPI(client)).row)
        } catch {
            if state.value == nil { state = .failed(Loadable<GroupRow>.message(for: error)) }
        }
    }
}
