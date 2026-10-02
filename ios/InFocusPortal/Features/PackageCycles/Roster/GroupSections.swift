import SwiftUI

/// Members, with a warning for anyone grouped together last cycle.
struct GroupMembersSection: View {
    let row: RosterRow
    let roster: RosterPayload
    let editable: Bool
    let add: () -> Void
    let remove: (String) -> Void

    var body: some View {
        let repeats = Dictionary(RosterLogic.repeatedPairs(row.memberUserIds, previous: roster.previousTeammatesByUser)
            .map { ($0.userId, $0.with) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(row.members.map { ($0.userId, $0.name) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Members · \(row.members.count)", actionTitle: editable ? "Add" : nil, action: editable ? add : nil)
            if row.members.isEmpty {
                Text("No members yet.").font(.small).foregroundStyle(Brand.muted)
            }
            ForEach(row.members) { member in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name).font(.bodyText).foregroundStyle(Brand.foreground)
                        if let with = repeats[member.userId] {
                            Text("Same group last cycle as \(with.compactMap { names[$0] }.joined(separator: ", "))")
                                .font(.small)
                                .foregroundStyle(Brand.warning)
                        }
                    }
                    Spacer()
                    if editable {
                        Button { remove(member.userId) } label: {
                            Image(systemName: "minus.circle").font(.title3).foregroundStyle(Brand.danger)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Remove \(member.name)")
                    }
                }
                .frame(minHeight: 44)
            }
        }
        .card()
    }
}

/// The one assigned producer (an associate or an executive).
struct GroupProducerSection: View {
    let label: String?
    let editable: Bool
    let change: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Assigned producer", actionTitle: editable ? "Change" : nil, action: editable ? change : nil)
            Text(label ?? "Unassigned")
                .font(.bodyText)
                .foregroundStyle(label == nil ? Brand.warning : Brand.foreground)
            Text("They review this group's stages in Groups and greenlight its pitch.")
                .font(.small)
                .foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Stage progress (read-only here: stages are reviewed in Groups).
struct GroupStagesSection: View {
    let row: RosterRow
    let openGroups: () -> Void

    var body: some View {
        let done = Set(RosterStage.done(row))
        let current = RosterStage.current(row)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Stages", actionTitle: "Open in Groups", action: openGroups)
            ForEach(RosterStage.allCases) { stage in
                HStack(spacing: 10) {
                    Image(systemName: done.contains(stage) ? "checkmark.circle.fill" : stage == current ? "circle.dotted" : "circle")
                        .foregroundStyle(done.contains(stage) ? Brand.green : stage == current ? Brand.warning : Brand.muted)
                        .accessibilityHidden(true)
                    Text(stage.title).font(.bodyText).foregroundStyle(Brand.foreground)
                    Spacer()
                    Text(done.contains(stage) ? "Done" : stage == current ? "In progress" : "Not started")
                        .font(.small)
                        .foregroundStyle(Brand.muted)
                }
                .accessibilityElement(children: .combine)
            }
            if row.hasExtension {
                Text("Extension: \(Self.days(row.extensionDays)) approved").font(.small).foregroundStyle(Brand.warning)
            }
        }
        .card()
    }

    static func days(_ value: Double) -> String {
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return value == 1 ? "1 day" : "\(number) days"
    }
}

/// Possible interviews, possible ideas and producer notes.
struct GroupNotesSection: View {
    let row: RosterRow
    let editable: Bool
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Notes", actionTitle: editable ? "Edit" : nil, action: editable ? edit : nil)
            note("Possible interviews", row.interviews)
            note("Possible ideas", row.ideas)
            note("Producer notes", row.notes)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(title, color: Brand.muted, size: 11)
            Text(text.isEmpty ? "None" : text)
                .font(.small)
                .foregroundStyle(text.isEmpty ? Brand.muted : Brand.secondary)
        }
    }
}

/// Move to another cycle, or delete (chart editors).
struct GroupActionsSection: View {
    let cycle: Int
    let cycles: [Int]
    let busy: Bool
    let move: (Int) -> Void
    let delete: () -> Void
    @State private var moveTarget: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Group")
            Menu {
                ForEach(cycles.filter { $0 != cycle }, id: \.self) { number in
                    Button("Move to Cycle \(number)") { moveTarget = number }
                }
            } label: {
                Label("Move to another cycle", systemImage: "arrow.right.arrow.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brandSecondary)
            .disabled(busy || cycles.count < 2)
            Button("Delete group", role: .destructive, action: delete)
                .buttonStyle(QuietDestructiveButtonStyle())
                .disabled(busy)
        }
        .card()
        .confirmationDialog("Move to Cycle \(moveTarget ?? 0)?", isPresented: Binding(get: { moveTarget != nil }, set: { if !$0 { moveTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Move") { if let moveTarget { move(moveTarget) } }
        } message: {
            Text("Members, uploads, comments, approvals, chats and extensions move with it. Grades stay with this cycle.")
        }
    }
}
