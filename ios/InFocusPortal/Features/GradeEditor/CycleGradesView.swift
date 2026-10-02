import SwiftUI

/// The web's cycle view: everyone's check-ins, Final Cut and publish state for
/// one cycle. Tap a person to grade them; "Publish all" publishes every graded,
/// unpublished row (`GET`/`POST api/grades/admin`).
struct CycleGradesView: View {
    @Environment(\.portalClient) private var client
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.verticalSizeClass) private var heightClass
    @State private var state: Loadable<CycleGrades> = .idle
    @State private var cycleNumber: Int?
    @State private var filter: GradeEditorLogic.Filter = .all
    @State private var search = ""
    @State private var confirmPublishAll = false
    @State private var publishing = false
    @State private var actionError: String?

    private var service: GradeEditorService { GradeEditorService(client: client) }
    /// iPad, or an iPhone in landscape: the spreadsheet layout.
    private var useTable: Bool { widthClass == .regular || heightClass == .compact }

    var body: some View {
        LoadableView(state, retry: { Task { await load() } }) { grades in
            content(grades)
        }
        .task { if state.value == nil { await load() } }
        .onAppear { if state.value != nil { Task { await load(quiet: true) } } }
        .confirmationDialog(publishAllTitle, isPresented: $confirmPublishAll, titleVisibility: .visible) {
            Button("Publish") { Task { await publishAll() } }
        } message: {
            Text("Students get an email and a notification for each grade.")
        }
    }

    private func content(_ grades: CycleGrades) -> some View {
        let rows = GradeEditorLogic.rows(grades.rows, filter: filter, search: search)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                header(grades)
                controls
                if let actionError { GradeEditorError(message: actionError) }
                if rows.isEmpty {
                    EmptyStateView(title: "Nobody here", message: "No one in this cycle matches this filter.")
                } else if useTable {
                    CycleGradesTable(cycleNumber: grades.activeCycleNumber, rows: rows)
                } else {
                    ForEach(rows) { row in
                        NavigationLink(value: Route.gradeEditor(.cycleStudent(cycle: grades.activeCycleNumber, userId: row.userId))) {
                            CycleGradeRowView(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Brand.gutter)
            .padding(.bottom, 24)
        }
        .refreshable { await load(quiet: true) }
    }

    private func header(_ grades: CycleGrades) -> some View {
        Nameplate(eyebrow: "Grade Editor", title: grades.activeCycle?.title ?? "Cycle \(grades.activeCycleNumber)",
                  subtitle: subtitle(grades)) {
            Menu {
                ForEach(grades.cycles) { cycle in
                    Button(cycle.title) { cycleNumber = cycle.cycleNumber; Task { await load() } }
                }
            } label: {
                Label("Cycle", systemImage: "chevron.up.chevron.down")
                    .font(.lexend(14, .medium, relativeTo: .subheadline))
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("Choose cycle")
        }
    }

    private func subtitle(_ grades: CycleGrades) -> String {
        var parts: [String] = []
        if let date = grades.activeCycle?.finalCutDate { parts.append("Final Cut \(GradeEditorLogic.dayLabel(date))") }
        if let average = grades.activeCycleAverage, average.publishedCount > 0 {
            parts.append("Avg \(GradeEditorLogic.points(average.averageTotal))/50")
        }
        return parts.isEmpty ? "No Final Cut date set" : parts.joined(separator: " · ")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Brand.muted).accessibilityHidden(true)
                TextField("Search names", text: $search)
                    .font(.bodyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GradeEditorLogic.Filter.allCases) { option in
                        Chip(title: option.rawValue, selected: filter == option) { filter = option }
                    }
                    Spacer(minLength: 8)
                    Button {
                        confirmPublishAll = true
                    } label: {
                        Label(publishing ? "Publishing…" : "Publish all", systemImage: "paperplane")
                    }
                    .buttonStyle(.brandSecondary)
                    .fixedSize()
                    .disabled(publishing || publishable.isEmpty)
                }
            }
        }
    }

    private var publishable: [CycleGradeRow] { GradeEditorLogic.publishable(state.value?.rows ?? []) }

    private var publishAllTitle: String {
        "Publish \(publishable.count) grade\(publishable.count == 1 ? "" : "s")?"
    }

    private func load(quiet: Bool = false) async {
        if !quiet || state.value == nil { state = .loading }
        do {
            let grades = try await service.cycle(cycleNumber)
            cycleNumber = grades.activeCycleNumber
            state = .loaded(grades)
        } catch {
            if !quiet || state.value == nil { state = .failed(Loadable<CycleGrades>.message(for: error)) }
        }
    }

    /// One at a time, like the web; stops at the first refusal and says why.
    private func publishAll() async {
        guard let grades = state.value else { return }
        publishing = true
        actionError = nil
        defer { publishing = false }
        for row in GradeEditorLogic.publishable(grades.rows) {
            do {
                try await service.setPublished(cycleNumber: grades.activeCycleNumber, userId: row.userId, published: true)
            } catch {
                actionError = "Couldn't publish \(row.displayName): \(Loadable<CycleGrades>.message(for: error))"
                break
            }
        }
        await load(quiet: true)
    }
}

/// A danger-tinted line with an icon and words (never color alone).
struct GradeEditorError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.small)
            .foregroundStyle(Brand.danger)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.dangerTint, in: RoundedRectangle(cornerRadius: Brand.radius))
            .accessibilityElement(children: .combine)
    }
}
