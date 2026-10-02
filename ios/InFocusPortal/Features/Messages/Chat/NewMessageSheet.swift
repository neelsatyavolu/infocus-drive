import SwiftUI

/// Producers start a direct message with any class member.
struct NewMessageSheet: View {
    let people: [ChatPerson]
    let pick: (ChatPerson) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [ChatPerson] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? people : people.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        NavigationStack {
            List(matches) { person in
                Button { pick(person) } label: {
                    HStack(spacing: 12) {
                        Avatar(name: person.name, size: 36)
                        Text(person.name).font(.bodyText).foregroundStyle(Brand.foreground)
                    }
                    .frame(minHeight: 44)
                }
                .listRowBackground(Brand.card)
            }
            .scrollContentBackground(.hidden)
            .brandBackground()
            .overlay {
                if people.isEmpty {
                    EmptyStateView(title: "Everyone's already here", message: "You have a chat with every class member.")
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search people")
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
