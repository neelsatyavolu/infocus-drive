import SwiftUI

/// Package Cycles: each cycle's five stage dates (Active, then Planned, then Closed),
/// the semester's cycle count, and Package of the Cycle winners.
struct CyclesView: View {
    @Bindable var store: CyclesStore
    @State private var editing: CycleDates?
    @State private var editingCount = false

    var body: some View {
        LoadableView(store.state, retry: { Task { await store.load() } }) { page in
            content(page)
        }
        .alert("Couldn't save", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .sheet(item: $editing) { cycle in
            CycleEditSheet(cycle: cycle) { await store.save($0) }
        }
        .sheet(isPresented: $editingCount) {
            if let page = store.state.value {
                CycleCountSheet(count: page.cycles.cyclesPerSemester) { await store.setCount($0) }
            }
        }
    }

    private func content(_ page: CyclesStore.Page) -> some View {
        let now = Date()
        let ordered = CycleSchedule.ordered(page.cycles.cycles, now: now)
        return VStack(alignment: .leading, spacing: 16) {
            Nameplate(eyebrow: "Package Cycles", title: "\(page.cycles.cyclesPerSemester) cycles this semester",
                      subtitle: "Stages close at 11:59 PM Pacific.") {
                if page.cycles.canEditCycleCount {
                    Button("Change") { editingCount = true }
                        .font(.lexend(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Brand.green)
                        .frame(minHeight: 44)
                }
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
            if let winners = page.winners, !winners.winners.isEmpty {
                WinnersSection(payload: winners, service: store.service)
            }
            ForEach(ordered, id: \.cycle.cycleNumber) { entry in
                CycleCard(cycle: entry.cycle, section: entry.section, now: now,
                          edit: page.cycles.canEdit ? { editing = entry.cycle } : nil)
            }
        }
    }
}

/// One cycle: status, next stage, and the five dates with Completed / in Nd / TBD.
struct CycleCard: View {
    let cycle: CycleDates
    let section: CycleSchedule.Section
    let now: Date
    let edit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CycleSchedule.name(cycle)).headline(.h3)
                    if let focus = cycle.focus?.trimmingCharacters(in: .whitespaces), !focus.isEmpty {
                        Text(focus).font(.small).foregroundStyle(Brand.secondary)
                    }
                }
                Spacer()
                StatusTag(text: section.label, tone: section == .active ? .success : section == .planned ? .warning : .neutral)
            }
            if section != .closed, let next = CycleSchedule.nextStage(cycle, now: now) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow("Next stage", size: 11)
                    Text("\(next.stage.title) · \(CycleSchedule.display(next.date))")
                        .font(.bodyText)
                        .foregroundStyle(Brand.foreground)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.greenTint, in: RoundedRectangle(cornerRadius: Brand.radius))
                .accessibilityElement(children: .combine)
            }
            VStack(spacing: 8) {
                ForEach(RosterStage.allCases) { stage in
                    StageDateRow(stage: stage, date: cycle.date(stage), status: CycleSchedule.status(cycle.date(stage), stage: stage, now: now))
                }
            }
            if let edit {
                Button("Edit dates", action: edit).buttonStyle(.brandSecondary)
            }
        }
        .card()
        .opacity(section == .closed ? 0.9 : 1)
    }
}

private struct StageDateRow: View {
    let stage: RosterStage
    let date: String?
    let status: CycleSchedule.Status

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(status == .tbd ? Brand.raised : status == .completed ? Brand.green : Brand.warning)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title).font(.small).foregroundStyle(Brand.foreground)
                Text(CycleSchedule.display(date)).font(.small).foregroundStyle(Brand.muted)
            }
            Spacer()
            StatusTag(text: label, tone: status == .completed ? .success : status == .tbd ? .neutral : .warning)
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch status {
        case .tbd: "TBD"
        case .completed: "Completed"
        case .dueToday: "Due today"
        case .inDays(let days): "in \(days)d"
        }
    }
}
