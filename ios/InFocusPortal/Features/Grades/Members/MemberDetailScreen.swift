import SwiftUI

/// One member: the chosen tab's note to write, their General note, and every other cycle's
/// note to read (Open switches the tab). Previous and next step through the list as filtered.
struct MemberDetailScreen: View {
    let store: MembersStore
    @State var memberId: String
    @Binding var tab: Int
    /// The member ids in list order, for previous and next.
    let order: [String]

    var body: some View {
        Group {
            if let member = store.payload?.members.first(where: { $0.id == memberId }) {
                content(member)
            } else {
                EmptyStateView(title: "Member not found", message: "They may have left the class roster.")
            }
        }
        .brandBackground()
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { stepper }
        .onDisappear { store.flushAll() }
    }

    private func content(_ member: MembersPayload.Member) -> some View {
        let cycles = store.payload?.cycles ?? []
        let others = cycles.filter { $0.cycleNumber != tab }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Nameplate(eyebrow: MembersLogic.tabTitle(tab), title: MembersLogic.label(member), subtitle: member.email)
                MemberNoteEditor(store: store, memberId: member.id, cycle: tab,
                                 focus: cycles.first { $0.cycleNumber == tab }?.focus, minHeight: 180)
                if tab != MembersLogic.generalCycle {
                    MemberNoteEditor(store: store, memberId: member.id, cycle: MembersLogic.generalCycle,
                                     focus: nil, minHeight: 100)
                }
                if !others.isEmpty {
                    otherCycles(others, member: member)
                }
            }
            .padding(Brand.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private func otherCycles(_ cycles: [MembersPayload.Cycle], member: MembersPayload.Member) -> some View {
        let withNotes = cycles.filter { !store.note(member.id, $0.cycleNumber).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let empty = cycles.filter { !withNotes.contains($0) }
        SectionHeader(title: tab == MembersLogic.generalCycle ? "Cycles" : "Other cycles")
        ForEach(withNotes) { cycle in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Eyebrow("Cycle \(MembersLogic.cycleCode(cycle.cycleNumber))", color: Brand.muted)
                    if !cycle.focus.isEmpty {
                        Text(cycle.focus).font(.small).foregroundStyle(Brand.muted).lineLimit(1)
                    }
                    Spacer()
                    Button("Open") { switchTab(cycle.cycleNumber) }
                        .font(.lexend(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Brand.green)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Open cycle \(cycle.cycleNumber) notes")
                }
                Text(store.note(member.id, cycle.cycleNumber))
                    .font(.bodyText)
                    .foregroundStyle(Brand.secondary)
                    .lineLimit(4)
            }
            .card()
        }
        if !empty.isEmpty {
            Text("No notes for Cycle \(empty.map { MembersLogic.cycleCode($0.cycleNumber) }.joined(separator: ", ")).")
                .font(.small)
                .foregroundStyle(Brand.muted)
        }
    }

    @ToolbarContentBuilder private var stepper: some ToolbarContent {
        let index = order.firstIndex(of: memberId)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { step(-1) } label: { Label("Previous member", systemImage: "chevron.up") }
                .disabled(index == nil || index == 0)
            Button { step(1) } label: { Label("Next member", systemImage: "chevron.down") }
                .disabled(index == nil || index == order.count - 1)
        }
    }

    private func switchTab(_ cycle: Int) {
        store.flushAll()
        tab = cycle
    }

    private func step(_ offset: Int) {
        guard let index = order.firstIndex(of: memberId), order.indices.contains(index + offset) else { return }
        store.flushAll()
        memberId = order[index + offset]
    }
}

/// One note with its save state; saves itself shortly after typing stops.
struct MemberNoteEditor: View {
    let store: MembersStore
    let memberId: String
    let cycle: Int
    let focus: String?
    let minHeight: CGFloat

    var body: some View {
        let state = store.noteState(memberId, cycle)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(MembersLogic.tabTitle(cycle), color: Brand.muted)
                if let focus, !focus.isEmpty {
                    Text(focus).font(.small).foregroundStyle(Brand.muted).lineLimit(1)
                }
                Spacer()
                if let label = state.label {
                    StatusTag(text: label, tone: tone(state))
                }
            }
            TextEditor(text: Binding(get: { store.note(memberId, cycle) },
                                     set: { store.setNote(memberId, cycle, $0) }))
                .font(.bodyText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(8)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
                .accessibilityLabel("\(MembersLogic.tabTitle(cycle)) notes")
            if case .failed(let message) = state {
                HStack {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.small)
                        .foregroundStyle(Brand.danger)
                    Spacer()
                    Button("Try again") { Task { await store.persist(MembersLogic.key(memberId, cycle)) } }
                        .font(.lexend(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Brand.green)
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private func tone(_ state: MemberNoteState) -> StatusTag.Tone {
        switch state {
        case .saved: .success
        case .failed: .danger
        case .dirty, .saving: .warning
        case .idle: .neutral
        }
    }
}
