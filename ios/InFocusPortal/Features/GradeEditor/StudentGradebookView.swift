import SwiftUI

/// One person's estimated semester grade as the Portal computes it (the web's
/// Student view): the letter, the three categories and each cycle this semester.
struct StudentGradebookView: View {
    let userId: String

    @Environment(\.portalClient) private var client
    @State private var state: Loadable<StudentGradebook> = .idle

    var body: some View {
        LoadableView(state, retry: { Task { await load() } }) { book in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Nameplate(eyebrow: "Gradebook", title: book.student.displayName, subtitle: book.student.email) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(book.estimated.letter ?? "—").font(.mono(28, .medium))
                            Text(GradeEditorLogic.percent(book.estimated.percentage)).font(.mono(13)).foregroundStyle(Brand.muted)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Estimated \(book.estimated.letter ?? "no grade yet"), \(GradeEditorLogic.percent(book.estimated.percentage))")
                    }
                    categories(book.estimated)
                    cycles(book)
                }
                .padding(Brand.gutter)
            }
            .refreshable { await load() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandBackground()
        .navigationTitle("Gradebook")
        .navigationBarTitleDisplayMode(.inline)
        .task { if state.value == nil { await load() } }
    }

    private func categories(_ estimated: StudentGradebook.Estimated) -> some View {
        VStack(spacing: 0) {
            category("Packages", estimated.packages.earned, estimated.packages.possible)
            Divider().overlay(Brand.line)
            category("Participation", estimated.participation.earned, estimated.participation.possible)
            Divider().overlay(Brand.line)
            category("Portfolio", estimated.portfolio.earned, estimated.portfolio.possible)
            Divider().overlay(Brand.line)
            row("Livestream", GradeEditorLogic.points(estimated.packages.livestreamPoints))
        }
        .card(padding: 4)
    }

    private func cycles(_ book: StudentGradebook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "This semester")
            ForEach(Array(book.cycles.enumerated()), id: \.element.cycleNumber) { index, cycle in
                NavigationLink(value: Route.gradeEditor(.cycleStudent(cycle: cycle.cycleNumber, userId: userId))) {
                    HStack {
                        Text(cycle.focus.map { "Cycle \(cycle.cycleNumber): \($0)" } ?? "Cycle \(cycle.cycleNumber)").font(.bodyText)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Final \(GradeEditorLogic.points(value(book.estimated.packages.finalCutPoints, index)))/50").font(.mono(14, .medium))
                            Text("Check-ins \(GradeEditorLogic.points(value(book.estimated.packages.checkInPoints, index)))/\(GradeEditorLogic.points(value(book.estimated.packages.checkInPossible, index)))")
                                .font(.mono(12)).foregroundStyle(Brand.muted)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Brand.muted)
                    }
                    .frame(minHeight: 52)
                    .padding(.horizontal, 14)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func value(_ values: [Double?], _ index: Int) -> Double? {
        values.indices.contains(index) ? values[index] : nil
    }

    private func category(_ title: String, _ earned: Double, _ possible: Double) -> some View {
        row(title, possible > 0 ? "\(GradeEditorLogic.points(earned))/\(GradeEditorLogic.points(possible))" : "—")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.bodyText)
            Spacer()
            Text(value).font(.mono(15, .medium))
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await GradeEditorService(client: client).gradebook(userId: userId)) } catch {
            state = .failed(Loadable<StudentGradebook>.message(for: error))
        }
    }
}
