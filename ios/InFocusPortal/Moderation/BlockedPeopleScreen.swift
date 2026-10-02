import SwiftUI

/// Settings → Blocked people: who's hidden in Messages on this iPhone, with Unblock.
struct BlockedPeopleScreen: View {
    @State private var blocks = BlockList.shared

    var body: some View {
        List {
            Section {
                if blocks.people.isEmpty {
                    Text("Nobody. Block someone from a message's menu in Messages.")
                        .font(.small)
                        .foregroundStyle(Brand.muted)
                } else {
                    ForEach(blocks.people) { person in
                        HStack {
                            Text(person.name)
                            Spacer()
                            Button("Unblock") { blocks.unblock(person.id) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Brand.green)
                        }
                    }
                }
            } footer: {
                Text("Their messages stay hidden on this iPhone only, and they aren't told. To flag a message to the InFocus adviser and executive producers, use Report.")
            }
        }
        .font(.bodyText)
        .scrollContentBackground(.hidden)
        .brandBackground()
        .navigationTitle("Blocked people")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A blocked person's message: hidden until tapped.
struct BlockedMessageRow: View {
    let reveal: () -> Void

    var body: some View {
        Button(action: reveal) {
            Label("Hidden: blocked. Tap to show.", systemImage: "eye.slash")
                .font(.small)
                .foregroundStyle(Brand.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows this message from someone you blocked")
    }
}
