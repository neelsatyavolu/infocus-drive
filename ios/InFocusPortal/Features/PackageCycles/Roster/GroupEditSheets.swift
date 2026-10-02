import SwiftUI

/// The group's topic.
struct GroupTopicSheet: View {
    @State var topic: String
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        RosterEditSheet(title: "Topic", saving: saving, canSave: true) {
            Section {
                TextField("What's the package about?", text: $topic, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.bodyText)
            } footer: {
                Text("\(topic.count)/280").font(.mono(12)).foregroundStyle(topic.count > 280 ? Brand.danger : Brand.muted)
            }
        } onSave: {
            await run { await save(topic.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    private func run(_ action: () async -> Bool) async {
        saving = true
        if await action() { dismiss() }
        saving = false
    }
}

/// Possible interviews, possible ideas and producer notes.
struct GroupNotesSheet: View {
    @State var interviews: String
    @State var ideas: String
    @State var notes: String
    let save: (String, String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        RosterEditSheet(title: "Notes", saving: saving, canSave: notes.count <= 1200) {
            field("Possible interviews", $interviews)
            field("Possible ideas", $ideas)
            field("Producer notes", $notes)
        } onSave: {
            saving = true
            if await save(interviews, ideas, notes) { dismiss() }
            saving = false
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        Section(title) {
            TextField(title, text: text, axis: .vertical)
                .lineLimit(2...8)
                .font(.bodyText)
        }
    }
}

/// A form sheet with Cancel and Save.
struct RosterEditSheet<Content: View>: View {
    let title: String
    let saving: Bool
    let canSave: Bool
    @ViewBuilder var content: Content
    let onSave: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { content }
                .scrollContentBackground(.hidden)
                .brandBackground()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving {
                            ProgressView()
                        } else {
                            Button("Save") { Task { await onSave() } }.disabled(!canSave)
                        }
                    }
                }
                .interactiveDismissDisabled(saving)
        }
    }
}
