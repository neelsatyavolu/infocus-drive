import SwiftUI

/// One person's grade for one cycle, editable the way the web table is: Final
/// Cut (points, Ungraded or Exempt), feedback and turned-in date save together;
/// check-ins save as picked; Publish sends it to the student.
struct StudentCycleEditor: View {
    let cycleNumber: Int
    let userId: String

    @Environment(\.portalClient) private var client
    @State private var state: Loadable<CycleGrades> = .idle
    @State private var draft = GradeDraft()
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    private var service: GradeEditorService { GradeEditorService(client: client) }

    var body: some View {
        LoadableView(state, retry: { Task { await load() } }) { grades in
            if let row = grades.rows.first(where: { $0.userId == userId }) {
                form(row, cycle: grades.activeCycle)
            } else {
                EmptyStateView(title: "Not in this gradebook",
                               message: "This person isn't graded in cycle \(cycleNumber).")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandBackground()
        .navigationTitle("Cycle \(cycleNumber)")
        .navigationBarTitleDisplayMode(.inline)
        .task { if state.value == nil { await load() } }
    }

    private func form(_ row: CycleGradeRow, cycle: GradeCycle?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Nameplate(eyebrow: cycle?.title ?? "Cycle \(cycleNumber)", title: row.displayName,
                          subtitle: row.email) { GradeStatusTag(row: row) }
                if let error { GradeEditorError(message: error) }
                if let notice {
                    Label(notice, systemImage: "checkmark.circle").font(.small).foregroundStyle(Brand.green)
                }
                FinalCutEditor(draft: $draft, row: row, finalCutDate: cycle?.finalCutDate)
                saveBar(row)
                CheckInEditor(row: row, busy: busy) { stage, choice in
                    Task { await setCheckIn(stage, choice) }
                }
                publishCard(row)
                NavigationLink(value: Route.gradeEditor(.gradebook(userId: row.userId))) {
                    Label("Semester gradebook", systemImage: "chart.bar").frame(maxWidth: .infinity)
                }
                .buttonStyle(.brandSecondary)
            }
            .padding(Brand.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await load() }
    }

    private func saveBar(_ row: CycleGradeRow) -> some View {
        let dirty = draft != GradeDraft(row)
        let parsed = GradeEditorLogic.parseFinalCut(draft.finalCutText)
        return Button {
            Task { await save(row) }
        } label: {
            Text(busy ? "Saving…" : "Save grade").frame(maxWidth: .infinity)
        }
        .buttonStyle(.brandPrimary)
        .disabled(busy || !dirty || (draft.mode == .score && parsed == nil))
    }

    private func publishCard(_ row: CycleGradeRow) -> some View {
        let dirty = draft != GradeDraft(row)
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Publish")
            Text(row.published
                 ? "The student can see this grade. Unpublish hides it again."
                 : GradeEditorLogic.canPublish(row)
                    ? "Publishing emails the student and adds it to their gradebook."
                    : "Enter a Final Cut score before publishing.")
                .font(.small)
                .foregroundStyle(Brand.secondary)
            if dirty { Text("Save your changes first.").font(.small).foregroundStyle(Brand.warning) }
            Button {
                Task { await setPublished(!row.published) }
            } label: {
                Text(row.published ? "Unpublish" : "Publish").frame(maxWidth: .infinity)
            }
            .buttonStyle(.brandSecondary)
            .disabled(busy || dirty || (!row.published && !GradeEditorLogic.canPublish(row)))
        }
        .card()
    }

    // MARK: Portal

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let grades = try await service.cycle(cycleNumber)
            state = .loaded(grades)
            if let row = grades.rows.first(where: { $0.userId == userId }) { draft = GradeDraft(row) }
        } catch {
            state = .failed(Loadable<CycleGrades>.message(for: error))
        }
    }

    private func run(_ success: String, _ action: () async throws -> Void) async {
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do {
            try await action()
            notice = success
            await load()
        } catch {
            self.error = Loadable<CycleGrades>.message(for: error)
        }
    }

    private func save(_ row: CycleGradeRow) async {
        guard let finalCut = draft.finalCutInput else {
            error = "Enter a Final Cut score from 0 to 50."
            return
        }
        await run("Saved.") {
            _ = try await service.save(SaveGradeBody(cycleNumber: cycleNumber, userId: userId, finalCut: finalCut,
                                                     feedback: draft.feedback, turnedInDate: draft.turnedInKey))
        }
    }

    private func setCheckIn(_ stage: CheckInStage, _ choice: GradeEditorLogic.CheckInChoice) async {
        await run("\(stage.label) saved.") {
            try await service.setCheckIn(cycleNumber: cycleNumber, userId: userId, stage: stage, points: choice.body)
        }
    }

    private func setPublished(_ published: Bool) async {
        await run(published ? "Published. The student was told." : "Unpublished.") {
            try await service.setPublished(cycleNumber: cycleNumber, userId: userId, published: published)
        }
    }
}
