import SwiftUI

/// Missing grades: who has no Final Cut grade, or an unpublished one, in each
/// started cycle (`view=missing`). People can be hidden from the list on this
/// device, like the web's per-browser exclusions.
struct MissingGradesView: View {
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<MissingGrades> = .idle
    @State private var excluded = Set(UserDefaults.standard.stringArray(forKey: Self.excludedKey) ?? [])
    @State private var showExcluded = false

    static let excludedKey = "gradeEditor.missingExcluded"
    private var service: GradeEditorService { GradeEditorService(client: client) }

    var body: some View {
        LoadableView(state, retry: { Task { await load() } }) { missing in
            VStack(spacing: 0) {
                Nameplate(eyebrow: "Grade Editor", title: "Missing grades",
                          subtitle: subtitle(missing))
                    .padding(.horizontal, Brand.gutter)
                list(missing)
            }
        }
        .task { if state.value == nil { await load() } }
    }

    private func subtitle(_ missing: MissingGrades) -> String {
        missing.consideredCycleNumbers.isEmpty ? "No cycle has grades yet"
            : "Started cycles: \(missing.consideredCycleNumbers.map(String.init).joined(separator: ", "))"
    }

    private func list(_ missing: MissingGrades) -> some View {
            List {
                let visible = missing.missingReport.filter { !excluded.contains($0.userId) && !$0.missing.isEmpty }
                if visible.isEmpty {
                    EmptyStateView(title: "Nothing missing", message: "Every started cycle is graded and published.")
                        .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(visible) { person in
                        MissingPersonRow(person: person)
                            .swipeActions { Button("Hide") { toggle(person.userId) }.tint(Brand.raised) }
                    }
                }
                let hidden = missing.missingReport.filter { excluded.contains($0.userId) }
                if !hidden.isEmpty {
                    Section {
                        DisclosureGroup("Hidden on this device (\(hidden.count))", isExpanded: $showExcluded) {
                            ForEach(hidden) { person in
                                HStack {
                                    Text(person.displayName).font(.bodyText)
                                    Spacer()
                                    Button("Show") { toggle(person.userId) }.foregroundStyle(Brand.green)
                                }
                                .frame(minHeight: 44)
                            }
                        }
                        .font(.bodyText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
    }

    private func toggle(_ userId: String) {
        if excluded.contains(userId) { excluded.remove(userId) } else { excluded.insert(userId) }
        UserDefaults.standard.set(Array(excluded).sorted(), forKey: Self.excludedKey)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await service.missing()) } catch {
            state = .failed(Loadable<MissingGrades>.message(for: error))
        }
    }
}

private struct MissingPersonRow: View {
    let person: MissingGrades.Person

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(person.displayName).font(.lexend(16, .semibold, relativeTo: .headline))
            ForEach(person.missing, id: \.cycleNumber) { entry in
                NavigationLink(value: Route.gradeEditor(.cycleStudent(cycle: entry.cycleNumber, userId: person.userId))) {
                    HStack {
                        Text("Cycle \(entry.cycleNumber)").font(.bodyText)
                        Spacer()
                        StatusTag(text: entry.status == .notEntered ? "Not entered" : "Unpublished",
                                  tone: entry.status == .notEntered ? .danger : .warning)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Brand.card)
    }
}
