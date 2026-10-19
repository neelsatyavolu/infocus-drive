import SwiftUI

/// Pick one member from a searchable list (appoint a manager, add crew, set a livestream's
/// manager). Nothing changes until a row is tapped.
struct PersonPickerSheet: View {
    let title: String
    let members: Loadable<[PortalMember]>
    /// Already chosen: left out of the list.
    var excluded: Set<String> = []
    let retry: () -> Void
    let pick: (PortalMember) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            LoadableView(members, retry: retry) { all in
                let shown = all.filter { !excluded.contains($0.id) && $0.matches(query) }
                List(shown) { member in
                    Button {
                        pick(member)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(name: member.label, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.label).font(.bodyText).foregroundStyle(Brand.foreground)
                                if let email = member.email {
                                    Text(email).font(.small).foregroundStyle(Brand.muted)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .listRowBackground(Brand.card)
                }
                .scrollContentBackground(.hidden)
                .overlay {
                    if shown.isEmpty {
                        if query.isEmpty {
                            ContentUnavailableView("No one to add", systemImage: "person.crop.circle.badge.questionmark")
                        } else {
                            ContentUnavailableView.search(text: query)
                        }
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search name or email")
            }
            .brandBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
