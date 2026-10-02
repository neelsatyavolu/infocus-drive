import SwiftUI

/// Pick a group's members (up to 20). Marks anyone who shared a group last cycle with a
/// current member: a warning, as on the web; the Portal doesn't block it.
struct MemberPickerSheet: View {
    let people: [RosterPerson]
    let previous: [String: [String]]
    let save: ([String]) async -> Bool
    @State private var selected: [String]
    @State private var query = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(people: [RosterPerson], memberIds: [String], previous: [String: [String]], save: @escaping ([String]) async -> Bool) {
        self.people = people
        self.previous = previous
        self.save = save
        _selected = State(initialValue: memberIds)
    }

    private var byId: [String: RosterPerson] { Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }

    private var matches: [RosterPerson] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let sorted = people.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { $0.displayName.localizedCaseInsensitiveContains(needle)
            || ($0.name ?? "").localizedCaseInsensitiveContains(needle) || ($0.email ?? "").localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !selected.isEmpty {
                    Section("In this group · \(selected.count)") {
                        ForEach(selected, id: \.self) { id in
                            personRow(id: id, name: byId[id]?.displayName ?? "Member", picked: true)
                        }
                    }
                }
                Section(query.isEmpty ? "Everyone" : "Matches") {
                    ForEach(matches.filter { !selected.contains($0.id) }) { person in
                        personRow(id: person.id, name: person.displayName, picked: false)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .brandBackground()
            .overlay { if people.isEmpty { ProgressView() } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search people")
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") {
                            Task {
                                saving = true
                                if await save(selected) { dismiss() }
                                saving = false
                            }
                        }
                    }
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func personRow(id: String, name: String, picked: Bool) -> some View {
        let repeatsWith = RosterLogic.lastCycleGroupmates(of: id, among: selected, previous: previous)
            .compactMap { byId[$0]?.displayName }
        return Button {
            if picked { selected.removeAll { $0 == id } } else if selected.count < 20 { selected.append(id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked ? Brand.green : Brand.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.bodyText).foregroundStyle(Brand.foreground)
                    if !repeatsWith.isEmpty {
                        Text("Same group last cycle as \(repeatsWith.joined(separator: ", "))")
                            .font(.small)
                            .foregroundStyle(Brand.warning)
                    }
                }
            }
            .frame(minHeight: 44)
        }
        .listRowBackground(Brand.card)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// Assign the group to one associate or executive, or unassign it.
struct ProducerPickerSheet: View {
    let options: [(person: AssignablePerson, isExecutive: Bool)]
    let selected: String?
    let save: (String?) async -> Bool
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { row(nil, "Unassigned", kind: nil) }
                Section("Executive producers") {
                    ForEach(options.filter(\.isExecutive), id: \.person.userId) { row($0.person.userId, $0.person.label, kind: "EP") }
                }
                Section("Associate producers") {
                    ForEach(options.filter { !$0.isExecutive }, id: \.person.userId) { row($0.person.userId, $0.person.label, kind: "AP") }
                }
            }
            .scrollContentBackground(.hidden)
            .brandBackground()
            .disabled(saving)
            .overlay { if saving { ProgressView() } }
            .navigationTitle("Assigned producer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ id: String?, _ name: String, kind: String?) -> some View {
        Button {
            Task {
                saving = true
                let done = id == selected ? true : await save(id)
                if done { dismiss() }
                saving = false
            }
        } label: {
            HStack {
                Text(name).font(.bodyText).foregroundStyle(Brand.foreground)
                if let kind { StatusTag(text: kind) }
                Spacer()
                if id == selected { Image(systemName: "checkmark").foregroundStyle(Brand.green) }
            }
            .frame(minHeight: 44)
        }
        .listRowBackground(Brand.card)
        .accessibilityAddTraits(id == selected ? .isSelected : [])
    }
}
