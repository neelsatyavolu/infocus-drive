import SwiftUI

/// Members (`/members`, producers): every class member with producer notes, a standing
/// General note and one per package cycle. Pick a tab, search, then open a person to write.
struct MembersScreen: View {
    @Environment(\.portalClient) private var client
    @State private var store: MembersStore?
    @State private var tab = MembersLogic.generalCycle
    @State private var filter = MemberNoteFilter.all
    @State private var search = ""
    @State private var openMemberId: String?

    var body: some View {
        Group {
            if let store {
                LoadableView(store.state, retry: { Task { await store.load() } }) { payload in
                    list(payload, store: store)
                }
                .navigationDestination(item: $openMemberId) { id in
                    MemberDetailScreen(store: store, memberId: id, tab: $tab, order: visibleIds(store))
                }
            } else {
                ScrollView { SkeletonList().padding(Brand.gutter) }
            }
        }
        .brandBackground()
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let store = self.store ?? MembersStore(service: MembersService(client: client))
            self.store = store
            await store.load()
        }
        .onDisappear { store?.flushAll() }
    }

    private func visibleIds(_ store: MembersStore) -> [String] {
        guard let payload = store.payload else { return [] }
        return MembersLogic.visible(payload.members, notes: store.drafts, tab: tab, filter: filter, search: search).map(\.id)
    }

    private func list(_ payload: MembersPayload, store: MembersStore) -> some View {
        let members = MembersLogic.visible(payload.members, notes: store.drafts, tab: tab, filter: filter, search: search)
        return List {
            Section {
                controls(payload, store: store)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            Section {
                if members.isEmpty {
                    EmptyStateView(title: payload.members.isEmpty ? "No members yet" : "No matches",
                                   message: payload.members.isEmpty ? "Class members show up once they sign in."
                                       : "Try another search or filter.")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(members) { member in
                        Button { openMemberId = member.id } label: { row(member, store: store) }
                            .listRowBackground(Brand.card)
                    }
                }
            } header: {
                Text("\(members.count) of \(payload.members.count)").font(.small)
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: "Search members")
        .refreshable { await store.load() }
    }

    private func controls(_ payload: MembersPayload, store: MembersStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                Picker("Notes for", selection: $tab) {
                    ForEach(store.tabs, id: \.self) { Text(MembersLogic.tabTitle($0)).tag($0) }
                }
            } label: {
                HStack {
                    Text(MembersLogic.tabTitle(tab)).headline(.h3)
                    Image(systemName: "chevron.down").font(.caption).accessibilityHidden(true)
                    Spacer()
                }
                .foregroundStyle(Brand.foreground)
                .frame(minHeight: 44)
            }
            .accessibilityLabel("Notes for \(MembersLogic.tabTitle(tab))")
            Text(MembersLogic.tabDescription(tab, cycles: payload.cycles))
                .font(.small)
                .foregroundStyle(Brand.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MemberNoteFilter.allCases) { option in
                        Chip(title: option.title, selected: filter == option) { filter = option }
                    }
                }
            }
        }
    }

    private func row(_ member: MembersPayload.Member, store: MembersStore) -> some View {
        let withNotes = MembersLogic.tabsWithNotes(store.drafts, memberId: member.id, tabs: store.tabs)
        let current = store.note(member.id, tab).trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(MembersLogic.label(member)).font(.lexend(16, .medium)).foregroundStyle(Brand.foreground)
                Spacer(minLength: 8)
                if let label = store.noteState(member.id, tab).label {
                    StatusTag(text: label, tone: store.noteState(member.id, tab) == .saved ? .success : .neutral)
                }
            }
            Text(current.isEmpty ? MembersLogic.coverage(withNotes) : current)
                .font(.small)
                .foregroundStyle(current.isEmpty ? Brand.muted : Brand.secondary)
                .lineLimit(2)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens notes")
    }
}
