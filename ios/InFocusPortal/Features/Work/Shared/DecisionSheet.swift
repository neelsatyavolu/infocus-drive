import SwiftUI

/// "Any feedback to add?" before approving a stage (the website's approve
/// dialog): Skip approves with no note; Approve with feedback sends the note
/// with the approval email.
struct DecisionSheet: View {
    let stageTitle: String
    let submit: (_ feedback: String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedback = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Any feedback to add?")
                    .headline(.h2)
                Text("Optional. The group gets it with the approval.")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
                TextField("Nice work. One thing for next time…", text: $feedback, axis: .vertical)
                    .font(.bodyText)
                    .lineLimit(4...10)
                    .padding(12)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
                }
                Spacer()
                Button(busy ? "Approving…" : "Approve with feedback") { run(feedback) }
                    .buttonStyle(.brandPrimary)
                    .disabled(busy || trimmed.isEmpty)
                Button("Skip and approve") { run("") }
                    .buttonStyle(.brandSecondary)
                    .disabled(busy)
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
