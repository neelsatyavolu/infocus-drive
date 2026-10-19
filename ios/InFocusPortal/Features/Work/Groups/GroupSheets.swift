import SwiftUI

/// A text sheet the Groups review pages share: a title, one quiet line, a field with a
/// character count, and one primary button (the toss, the cycle note, group notes, a
/// revision note). `save` throws to keep the sheet open with the Portal's message.
struct GroupTextSheet: View {
    let title: String
    let message: String
    let placeholder: String
    let actionTitle: String
    var maxLength: Int
    var allowsEmpty = true
    var validate: (String) -> String? = { _ in nil }
    let initial: String
    let save: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(message).font(.small).foregroundStyle(Brand.secondary)
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.bodyText)
                    .lineLimit(5...14)
                    .padding(12)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                HStack {
                    if let problem = shownProblem {
                        Label(problem, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
                    }
                    Spacer()
                    Text("\(text.count)/\(maxLength)")
                        .font(.mono(12))
                        .foregroundStyle(text.count > maxLength ? Brand.danger : Brand.muted)
                }
                Spacer()
                Button(busy ? "Saving…" : actionTitle) { run() }
                    .buttonStyle(.brandPrimary)
                    .disabled(busy || !canSave)
            }
            .padding(Brand.gutter)
            .brandBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { text = initial }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { text.count <= maxLength && (allowsEmpty || !trimmed.isEmpty) && validate(text) == nil }
    private var shownProblem: String? { error ?? (trimmed.isEmpty ? nil : validate(text)) }

    private func run() {
        busy = true
        error = nil
        Task {
            do {
                try await save(text)
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

/// Initial Cut "Needs revisions" (`SUBMIT_REVIEW`): an optional note posted to the group's
/// feedback first (when this producer may still comment), then the review is submitted.
struct RevisionsSheet: View {
    let canAddNote: Bool
    let submit: (_ note: String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Send back for revisions?").headline(.h2)
                Text("The group sees the review and uploads a new version. The same stage reviews it again. Timed notes on the cut go on the review page.")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
                if canAddNote {
                    TextField("What needs to change? (optional)", text: $note, axis: .vertical)
                        .font(.bodyText)
                        .lineLimit(4...10)
                        .padding(12)
                        .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                        .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
                }
                Spacer()
                Button(busy ? "Submitting…" : "Submit review (needs revisions)") { run() }
                    .buttonStyle(.brandPrimary)
                    .disabled(busy || note.count > GroupReviewLogic.noteMax)
            }
            .padding(Brand.gutter)
            .brandBackground()
            .navigationTitle("Initial Cut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func run() {
        busy = true
        error = nil
        Task {
            do {
                try await submit(note.trimmingCharacters(in: .whitespacesAndNewlines))
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
