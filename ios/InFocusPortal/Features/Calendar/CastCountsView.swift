import SwiftUI

/// Anchors & PA counts (executives only, like the Portal's Master Calendar button): how many
/// times each class member is on the calendar as an anchor or PA announcer, upcoming days
/// included, so producers can spread the jobs around.
struct CastCountsView: View {
    @Environment(\.portalClient) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var state: Loadable<[CastCount]> = .idle
    @State private var query = ""

    var body: some View {
        NavigationStack {
            LoadableView(state, retry: { Task { await load() } }) { people in
                List {
                    Section {
                        ForEach(filtered(people)) { row($0) }
                    } header: {
                        VStack(alignment: .leading, spacing: 16) {
                            summary(people).textCase(nil)
                            HStack {
                            Text("Name")
                            Spacer()
                            Text("Anchor").frame(width: 64, alignment: .trailing)
                            Text("PA").frame(width: 44, alignment: .trailing)
                            }
                            .font(.lexend(11, .medium, relativeTo: .caption2))
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .searchable(text: $query, prompt: "Search names")
            }
            .brandBackground()
            .navigationTitle("Anchors & PA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await CalendarEditAPI.current(client).castCounts())
        } catch {
            state = .failed(Loadable<[CastCount]>.message(for: error))
        }
    }

    private func filtered(_ people: [CastCount]) -> [CastCount] {
        let sorted = CastCountSummary.sorted(people)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? sorted : sorted.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private func summary(_ people: [CastCount]) -> some View {
        let summary = CastCountSummary(people)
        return HStack(spacing: 8) {
            tile("Roster", summary.roster)
            tile("No anchor", summary.neverAnchored)
            tile("No PA", summary.neverPa)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tile(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.mono(22, .medium)).monospacedDigit().foregroundStyle(Brand.foreground)
            Text(label.uppercased()).font(.lexend(10, .medium, relativeTo: .caption2)).tracking(1.1).foregroundStyle(Brand.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }

    private func row(_ person: CastCount) -> some View {
        HStack {
            Text(person.name).font(.bodyText)
            Spacer()
            count(person.anchors).frame(width: 64, alignment: .trailing)
            count(person.pa).frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(person.name): \(person.anchors) anchor, \(person.pa) PA")
    }

    /// Zeros show as a dash, as on the Portal.
    private func count(_ value: Int) -> some View {
        Text(value == 0 ? "–" : "\(value)")
            .font(.mono(15, value == 0 ? .regular : .medium))
            .monospacedDigit()
            .foregroundStyle(value == 0 ? Brand.muted : Brand.foreground)
    }
}

/// The three numbers on top of Anchors & PA counts, and the A–Z order.
struct CastCountSummary: Equatable {
    let roster: Int
    let neverAnchored: Int
    let neverPa: Int

    init(_ people: [CastCount]) {
        roster = people.count
        neverAnchored = people.filter { $0.anchors == 0 }.count
        neverPa = people.filter { $0.pa == 0 }.count
    }

    static func sorted(_ people: [CastCount]) -> [CastCount] {
        people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
