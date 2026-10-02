import SwiftUI

/// The comment thread on a package stage. Opening it marks the stage read
/// (the student's unread dots); producers who may comment get a composer.
struct StageCommentsSection: View {
    let rowId: String
    let stage: String
    let canPost: Bool
    let api: WorkAPI
    /// A producer's comment on A-roll/B-roll asks the group for changes.
    var postHint: String?

    @State private var state: Loadable<[StageComment]> = .idle
    @State private var draft = ""
    @State private var posting = false
    @State private var postError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Feedback")
            switch state {
            case .idle, .loading:
                Skeleton(height: 60)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let comments):
                if comments.isEmpty {
                    Text(canPost ? "No feedback yet. Leave the first note." : "No feedback yet.")
                        .font(.small)
                        .foregroundStyle(Brand.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                } else {
                    ForEach(comments) { comment in CommentRow(comment: comment) }
                }
            }
            if canPost { composer }
        }
        .task(id: "\(rowId)/\(stage)") { await load() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Write feedback…", text: $draft, axis: .vertical)
                .font(.bodyText)
                .lineLimit(2...6)
                .padding(12)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
            if let postHint {
                Text(postHint).font(.small).foregroundStyle(Brand.muted)
            }
            if let postError {
                Label(postError, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
            }
            Button(posting ? "Posting…" : "Post feedback") { Task { await post() } }
                .buttonStyle(.brandPrimary)
                .disabled(posting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.comments(rowId, stage).comments)
        } catch {
            state = .failed(Loadable<[StageComment]>.message(for: error))
        }
    }

    private func post() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        posting = true
        postError = nil
        defer { posting = false }
        do {
            try await api.postComment(rowId, stage, body)
            draft = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } catch {
            postError = Loadable<Void>.message(for: error)
        }
    }
}

private struct CommentRow: View {
    let comment: StageComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(comment.authorName).font(.lexend(14, .semibold)).foregroundStyle(Brand.foreground)
                Spacer()
                Text(comment.createdAt, format: .relative(presentation: .named))
                    .font(.small)
                    .foregroundStyle(Brand.muted)
            }
            Text(comment.body)
                .font(.bodyText)
                .foregroundStyle(Brand.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }
}
