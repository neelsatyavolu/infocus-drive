import SwiftUI

/// The web's Total view: official credits per person (participation, check-ins,
/// livestream, portfolio and each cycle's Final Cut). "—" means not gradeable yet.
/// Notes save with `setTotalNotes`.
struct GradeTotalsView: View {
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<GradeTotals> = .idle
    @State private var search = ""
    @State private var editingNotes: GradeTotals.Row?

    private var service: GradeEditorService { GradeEditorService(client: client) }

    var body: some View {
        LoadableView(state, retry: { Task { await load() } }) { totals in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Nameplate(eyebrow: "Grade Editor", title: "Totals",
                              subtitle: "Official scores this semester")
                    searchField
                    ForEach(filtered(totals.totalsRows)) { row in
                        TotalsRowCard(row: row, cycles: totals.cycles) { editingNotes = row }
                    }
                }
                .padding(.horizontal, Brand.gutter)
                .padding(.bottom, 24)
            }
            .refreshable { await load() }
        }
        .task { if state.value == nil { await load() } }
        .sheet(item: $editingNotes) { row in
            TotalNotesSheet(row: row) { notes in
                try await service.setTotalNotes(userId: row.userId, notes: notes)
                await load()
            }
        }
    }

    private var searchField: some View {
        TextField("Search names", text: $search)
            .font(.bodyText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
    }

    private func filtered(_ rows: [GradeTotals.Row]) -> [GradeTotals.Row] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? rows : rows.filter { $0.displayName.lowercased().contains(query) }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await service.totals()) } catch {
            state = .failed(Loadable<GradeTotals>.message(for: error))
        }
    }
}

private struct TotalsRowCard: View {
    let row: GradeTotals.Row
    let cycles: [GradeCycle]
    let editNotes: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(row.displayName).font(.lexend(16, .semibold, relativeTo: .headline))
                Spacer()
                NavigationLink(value: Route.gradeEditor(.gradebook(userId: row.userId))) {
                    Label("Gradebook", systemImage: "chart.bar").font(.small)
                }
                .frame(minHeight: 44)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 12) {
                stat("Participation", "\(GradeEditorLogic.points(row.participationEarned))/\(GradeEditorLogic.points(row.participationPossible))")
                stat("Check-ins", row.checkInPoints == nil ? "—" : "\(GradeEditorLogic.points(row.checkInPoints))/\(GradeEditorLogic.points(row.checkInPossible))")
                stat("Livestream", GradeEditorLogic.points(row.livestreamPoints), detail: "\(GradeEditorLogic.points(row.livestreamHours)) h")
                stat("Portfolio", GradeEditorLogic.points(row.portfolioPoints))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(row.cycleTotals, id: \.cycleNumber) { total in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("C\(total.cycleNumber)").font(.lexend(10, .medium, relativeTo: .caption2)).foregroundStyle(Brand.muted)
                            Text(total.finalCutState == .exempt ? "EX" : GradeEditorLogic.points(total.totalPoints)).font(.mono(14, .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.tagRadius))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Cycle \(total.cycleNumber) Final Cut \(total.finalCutState == .exempt ? "exempt" : GradeEditorLogic.points(total.totalPoints))")
                    }
                }
            }
            Button(action: editNotes) {
                HStack {
                    Image(systemName: "note.text").accessibilityHidden(true)
                    Text(row.notes.isEmpty ? "Add a note" : row.notes).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer()
                }
                .font(.small)
                .foregroundStyle(row.notes.isEmpty ? Brand.muted : Brand.secondary)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.notes.isEmpty ? "Add a note" : "Note: \(row.notes)")
        }
        .card(padding: 14)
    }

    private func stat(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.lexend(10, .medium, relativeTo: .caption2)).tracking(1).foregroundStyle(Brand.muted)
                .lineLimit(1)
            Text(value).font(.mono(15, .medium))
            if let detail { Text(detail).font(.mono(11)).foregroundStyle(Brand.muted) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Edits one person's Total-view note.
private struct TotalNotesSheet: View {
    let row: GradeTotals.Row
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let error { GradeEditorError(message: error) }
                TextEditor(text: $notes)
                    .font(.bodyText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                Text("\(notes.count)/\(GradeEditorLogic.maxTotalNotes)").font(.mono(12)).foregroundStyle(Brand.muted)
            }
            .padding(Brand.gutter)
            .brandBackground()
            .navigationTitle(row.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await save(String(notes.prefix(GradeEditorLogic.maxTotalNotes)))
                                dismiss()
                            } catch {
                                self.error = Loadable<GradeTotals>.message(for: error)
                            }
                        }
                    }
                    .disabled(saving || notes == row.notes)
                }
            }
            .onAppear { notes = row.notes }
        }
        .presentationDetents([.medium, .large])
    }
}
