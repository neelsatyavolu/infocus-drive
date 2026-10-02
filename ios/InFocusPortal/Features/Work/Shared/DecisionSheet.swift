import SwiftUI

/// "Any feedback to add?" before approving a stage (the website's approve
/// dialog): Skip approves with no note; Approve with feedback sends the note
/// with the approval email. Sending back asks for the note the group will see.
struct DecisionSheet: View {
    enum Mode { case approve, sendBack }

    let mode: Mode
    let stageTitle: String
    let submit: (_ feedback: String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedback = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(mode == .approve ? "Any feedback to add?" : "What needs to change?")
                    .headline(.h2)
                Text(mode == .approve
                     ? "Optional. The group gets it with the approval."
                     : "The group sees this note and uploads a new version.")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
                TextField(mode == .approve ? "Nice work. One thing for next time…" : "Feedback for the group",
                          text: $feedback, axis: .vertical)
                    .font(.bodyText)
                    .lineLimit(4...10)
                    .padding(12)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
                }
                Spacer()
                if mode == .approve {
                    Button(busy ? "Approving…" : "Approve with feedback") { run(feedback) }
                        .buttonStyle(.brandPrimary)
                        .disabled(busy || trimmed.isEmpty)
                    Button("Skip and approve") { run("") }
                        .buttonStyle(.brandSecondary)
                        .disabled(busy)
                } else {
                    Button(busy ? "Sending…" : "Send back") { run(feedback) }
                        .buttonStyle(.brandPrimary)
                        .disabled(busy || trimmed.isEmpty)
                }
            }
            .padding(Brand.gutter)
            .brandBackground()
            .navigationTitle(stageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var trimmed: String { feedback.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func run(_ note: String) {
        busy = true
        error = nil
        Task {
            do {
                try await submit(note)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                self.error = Loadable<Void>.message(for: error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            busy = false
        }
    }
}
