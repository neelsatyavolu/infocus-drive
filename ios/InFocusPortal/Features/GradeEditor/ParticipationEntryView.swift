import SwiftUI

/// Participation for one class day: full marks save at once; a lower score waits
/// for another producer to approve it (the Portal decides, `POST api/participation`).
/// Docked scores from others are reviewed in Pending.
struct ParticipationEntryView: View {
    @Environment(\.portalClient) private var client
    @State private var weekStart = GradeEditorLogic.weekStart(of: Date())
    @State private var day: String?
    @State private var state: Loadable<ParticipationWeek> = .idle
    @State private var edits: [String: ParticipationEdit] = [:]
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?
    @State private var showPending = false
    @State private var pendingDiscard: (() -> Void)?

    private var service: GradeEditorService { GradeEditorService(client: client) }

    var body: some View {
        LoadableView(state, retry: { Task { await load() } }) { week in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    weekBar(week)
                    Label("Full marks count right away. A lower score goes to another producer to approve before it counts.",
                          systemImage: "info.circle")
                        .font(.small).foregroundStyle(Brand.secondary)
                    if let error { GradeEditorError(message: error) }
                    if let message { Label(message, systemImage: "checkmark.circle").font(.small).foregroundStyle(Brand.green) }
                    if let day, let max = week.gradedDays.first(where: { $0.date == day })?.maxPoints {
                        ForEach(week.students, id: \.id) { student in
                            ParticipationCell(student: student, week: week, date: day, max: max,
                                              edit: binding(student.id, week: week, date: day, max: max))
                        }
                    } else {
                        EmptyStateView(title: "No class days", message: "This week has no graded days (shows and holidays are 0 points).")
                    }
                }
                .padding(.horizontal, Brand.gutter)
                .padding(.bottom, 96)
            }
            .refreshable { await load() }
            .safeAreaInset(edge: .bottom) { saveBar(week) }
        }
        .task { if state.value == nil { await load() } }
        .sheet(isPresented: $showPending, onDismiss: { Task { await load() } }) {
            ParticipationRequestsSheet()
        }
        .confirmationDialog("Discard unsaved scores?", isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { edits = [:]; pendingDiscard?(); pendingDiscard = nil }
        }
    }

    private func weekBar(_ week: ParticipationWeek) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { change { weekStart = GradeEditorLogic.shiftWeek(weekStart, by: -1); Task { await load() } } } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Previous week")
                Spacer()
                Text("Week of \(GradeEditorLogic.dayLabel(weekStart))").headline(.h3)
                Spacer()
                Button { change { weekStart = GradeEditorLogic.shiftWeek(weekStart, by: 1); Task { await load() } } } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next week")
            }
            HStack(spacing: 8) {
                ForEach(week.gradedDays, id: \.date) { graded in
                    Chip(title: "\(GradeEditorLogic.dayLabel(graded.date).components(separatedBy: ",").first ?? "") · \(graded.maxPoints)",
                         selected: day == graded.date) { change { day = graded.date } }
                        .fixedSize()
                        .accessibilityLabel("\(GradeEditorLogic.dayLabel(graded.date)), \(graded.maxPoints) points")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let day, let max = week.gradedDays.first(where: { $0.date == day })?.maxPoints {
                    Button("Rest full") { markRestFull(week, date: day, max: max) }
                        .buttonStyle(.brandQuiet)
                        .fixedSize()
                        .accessibilityHint("Gives full marks to everyone not entered yet for this day")
                }
                Spacer(minLength: 0)
                Button { showPending = true } label: {
                    Label("Pending \(week.pendingCount)", systemImage: "hourglass")
                }
                .buttonStyle(.brandQuiet)
                .fixedSize()
            }
        }
        .card(padding: 12)
    }

    @ViewBuilder private func saveBar(_ week: ParticipationWeek) -> some View {
        let changes = day.map { GradeEditorLogic.changedEntries(edits: edits, week: week, date: $0) } ?? []
        if !changes.isEmpty {
            Button {
                Task { await save(changes) }
            } label: {
                Text(saving ? "Saving…" : "Save \(changes.count) score\(changes.count == 1 ? "" : "s")").frame(maxWidth: .infinity)
            }
            .buttonStyle(.brandPrimary)
            .disabled(saving)
            .padding(Brand.gutter)
            .background(.bar)
        }
    }

    /// Full marks for everyone with nothing saved or pending on this day.
    private func markRestFull(_ week: ParticipationWeek, date: String, max: Int) {
        for student in week.students where week.entry(student.id, date) == nil && week.pending(student.id, date) == nil {
            edits[student.id] = ParticipationEdit(points: max, notes: "")
        }
    }

    /// Runs `action`, asking first when unsaved scores would be lost.
    private func change(_ action: @escaping () -> Void) {
        if edits.isEmpty { action() } else { pendingDiscard = action }
    }

    private func binding(_ userId: String, week: ParticipationWeek, date: String, max: Int) -> Binding<ParticipationEdit> {
        Binding {
            edits[userId] ?? ParticipationCell.saved(userId, week: week, date: date, max: max)
        } set: {
            edits[userId] = $0
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let week = try await service.participation(weekStart: weekStart)
            state = .loaded(week)
            if day == nil || !week.gradedDays.contains(where: { $0.date == day }) {
                let today = GradeEditorLogic.dateKey(Date())
                day = week.gradedDays.last(where: { $0.date <= today })?.date ?? week.gradedDays.first?.date
            }
        } catch {
            state = .failed(Loadable<ParticipationWeek>.message(for: error))
        }
    }

    private func save(_ entries: [ParticipationEntryBody]) async {
        saving = true
        error = nil
        message = nil
        defer { saving = false }
        do {
            let result = try await service.saveParticipation(entries)
            edits = [:]
            message = result.pending
                ? "Saved \(result.saved). \(result.itemCount) lower score\(result.itemCount == 1 ? "" : "s") sent to another producer to approve."
                : "Saved \(result.saved) score\(result.saved == 1 ? "" : "s")."
            await load()
        } catch {
            self.error = Loadable<ParticipationWeek>.message(for: error)
        }
    }
}
