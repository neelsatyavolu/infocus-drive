import SwiftUI

/// Producers: post an announcement to the whole class (`POST api/announcements`).
/// Mentions are added on the Portal for now.
struct ComposeAnnouncementView: View {
    @Environment(\.portalClient) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var posting = false
    @FocusState private var focused: Bool
    private let feed = AnnouncementsStore.shared
    private let limit = 4000

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Everyone in the class sees this.")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
                TextEditor(text: $text)
                    .font(.bodyText)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(focused ? Brand.green : Brand.control))
                    .accessibilityLabel("Announcement")
                Text("\(text.count) / \(limit)")
                    .font(.mono(12))
                    .foregroundStyle(text.count > limit ? Brand.danger : Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(Brand.gutter)
            .brandBackground()
            .navigationTitle("New announcement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(posting ? "Posting…" : "Post") { Task { await post() } }
                        .disabled(!canPost)
                }
            }
            .onAppear { focused = true }
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canPost: Bool { !posting && !trimmed.isEmpty && trimmed.count <= limit }

    private func post() async {
        posting = true
        defer { posting = false }
        if await feed.post(trimmed, api: CalendarAPI.current(client)) { dismiss() }
    }
}
