import SwiftUI

/// Producers' Groups: every package this cycle they can see, with the same
/// status pills as the website. Assigned packages (and, for executives,
/// Stage 2/3 and Final Cut work) are "Yours"; the rest are "Other groups".
struct GroupsScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.portalClient) private var client
    @Environment(BadgeCenter.self) private var badges
    @State private var state: Loadable<GroupsPayload> = .idle
    @State private var cycle: Int?
    @State private var search = ""
    @State private var showOthers = false

    var body: some View {
        ScrollView {
            LoadableView(state, retry: { Task { await load() } }) { payload in
                VStack(alignment: .leading, spacing: 16) {
                    cyclePicker(payload)
                    let groups = filtered(payload)
                    if groups.primary.isEmpty && groups.other.isEmpty {
                        EmptyStateView(title: search.isEmpty ? "No groups yet" : "No matches",
                                       message: search.isEmpty ? "Groups appear once the Package Cycle roster is set." : "Try another topic or name.")
                            .card()
                    }
                    if !groups.primary.isEmpty {
                        SectionHeader(title: "Yours · \(groups.primary.count)")
                        ForEach(groups.primary) { GroupTile(row: $0) }
                    }
                    if !groups.other.isEmpty {
                        DisclosureGroup(isExpanded: $showOthers) {
                            VStack(spacing: 12) { ForEach(groups.other) { GroupTile(row: $0) } }
                                .padding(.top, 8)
                        } label: {
                            Eyebrow("Other groups · \(groups.other.count)", color: Brand.muted)
                        }
                        .tint(Brand.muted)
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .searchable(text: $search, prompt: "Topic or member")
        .refreshable { await load() }
        .brandBackground()
        .navigationTitle("Groups")
        .task { if state.value == nil { await load() } }
    }

    private func cyclePicker(_ payload: GroupsPayload) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(payload.cycles) { info in
                    let active = info.cycleNumber == payload.activeCycleNumber
                    Button {
                        cycle = info.cycleNumber
                        Task { await load() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Cycle").font(.lexend(12, .semibold)).tracking(1.3)
                            Text(String(format: "%02d", info.cycleNumber)).font(.mono(12, .medium))
                        }
                        .textCase(.uppercase)
                        .foregroundStyle(active ? Brand.onBrand : Brand.secondary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(active ? Brand.fill : Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                        .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(active ? .clear : Brand.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cycle \(info.cycleNumber)")
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
    }

    private func filtered(_ payload: GroupsPayload) -> (primary: [GroupRow], other: [GroupRow]) {
        guard let user = session.user else { return ([], []) }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = GroupsVisibility.visible(payload.rows, for: user).filter { row in
            query.isEmpty || row.topic.lowercased().contains(query) || row.memberNames.lowercased().contains(query)
        }
        let primary = rows.filter { GroupsVisibility.isPrimary($0, for: user) }
        return (primary, rows.filter { !GroupsVisibility.isPrimary($0, for: user) })
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let payload = try await workAPI(client).groups(cycle)
            state = .loaded(payload)
            if let user = session.user {
                let waiting = GroupsVisibility.visible(payload.rows, for: user).filter {
                    GroupsVisibility.isPrimary($0, for: user) && GroupTileStatus.of($0).tone == .warning
                }
                badges.set(waiting.count, for: .work)
            }
        } catch {
            if state.value == nil { state = .failed(Loadable<GroupsPayload>.message(for: error)) }
        }
    }
}

/// One package: topic, members, the status pill, and the stage it's on.
struct GroupTile: View {
    let row: GroupRow

    var body: some View {
        let status = GroupTileStatus.of(row)
        let stage = GroupStage.current(for: row)
        NavigationLink(value: Route.work(.group(rowId: row.id, stage: nil))) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.topic).font(.h3).foregroundStyle(Brand.foreground).multilineTextAlignment(.leading)
                        Text(row.memberNames.isEmpty ? "No members yet" : row.memberNames)
                            .font(.small).foregroundStyle(Brand.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").foregroundStyle(Brand.muted).accessibilityHidden(true)
                }
                HStack(spacing: 8) {
                    StatusTag(text: status.label, tone: status.tone)
                    Spacer(minLength: 0)
                    StageDots(row: row, current: stage)
                }
                if let producer = row.assignedProducer?.displayName {
                    Label(producer, systemImage: "person.crop.circle").font(.small).foregroundStyle(Brand.muted)
                }
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.topic). \(status.label). \(row.memberNames)")
    }
}

/// Five dots for pitch → final cut: filled when done, ringed for the current stage.
struct StageDots: View {
    let row: GroupRow
    let current: GroupStage

    var body: some View {
        HStack(spacing: 5) {
            ForEach(GroupStage.allCases) { stage in
                Circle()
                    .fill(stage.isDone(for: row) ? Brand.green : Color.clear)
                    .overlay(Circle().strokeBorder(stage == current ? Brand.green : Brand.control, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
            }
        }
        .accessibilityHidden(true)
    }
}
