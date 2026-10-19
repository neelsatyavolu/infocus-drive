import SwiftUI

/// The comment thread on a package stage. Opening it marks the stage read
/// (the student's unread dots); producers who may comment get a composer.
/// The group thread leaves out notes on single A-roll clips (`clipId` shows
/// only that clip's notes), and members or producers can mark a note resolved.
struct StageCommentsSection: View {
    let rowId: String
    let stage: String
    let canPost: Bool
    let api: WorkAPI
    /// A producer's comment on A-roll/B-roll asks the group for changes.
    var postHint: String?
    /// One A-roll clip's notes instead of the group thread.
    var clipId: String?
    /// Change it to load the thread again (after an upload, for example).
    var refreshKey = 0

    @State private var state: Loadable<[StageComment]> = .idle
    @State private var onClips = 0
    @State private var draft = ""
    @State private var posting = false
    @State private var postError: String?
    @State private var resolvingId: String?
    @State private var reportTarget: ReportTarget?
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: clipId == nil ? "Feedback" : "Feedback on this clip")
            switch state {
            case .idle, .loading:
                Skeleton(height: 60)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let comments):
                if comments.isEmpty {
                    Text(emptyText)
                        .font(.small)
                        .foregroundStyle(Brand.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                } else {
                    ForEach(comments) { comment in
                        CommentRow(comment: comment, resolving: resolvingId == comment.id,
                                   onToggleResolved: { Task { await setResolved(comment) } },
                                   onOpenReview: { href in router.openPortal(StageGuide.portalPath(href), title: "Review") })
                            .contextMenu {
                                if !isMine(comment) {
                                    Button("Report comment", systemImage: "flag") {
                                        reportTarget = ReportTarget(report: .comment(comment.id), authorName: comment.authorName,
                                                                    excerpt: comment.body)
                                    }
                                }
                            }
                    }
                }
                if onClips > 0 {
                    Text("\(onClips) note\(onClips == 1 ? " is" : "s are") on single clips. Open a clip to read them.")
                        .font(.small)
                        .foregroundStyle(Brand.muted)
                }
            }
            if canPost { composer }
        }
        .task(id: "\(rowId)/\(stage)/\(clipId ?? "")/\(refreshKey)") { await load() }
        .sheet(item: $reportTarget) { ReportSheet(target: $0) }
    }

    private var emptyText: String {
        if clipId != nil { return "No notes on this clip yet." }
        return canPost ? "No feedback yet. Leave the first note." : "No producer feedback yet."
    }

    private func isMine(_ comment: StageComment) -> Bool {
        guard let mine = session.user?.email.lowercased(), let author = comment.author.email?.lowercased() else { return false }
        return mine == author
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(clipId == nil ? "Write feedback…" : "Write feedback for this clip…", text: $draft, axis: .vertical)
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
            let all = try await api.comments(rowId, stage).comments
            let thread = StageThread(all, clipId: clipId)
            onClips = thread.onClips
            state = .loaded(thread.comments)
        } catch {
            state = .failed(Loadable<[StageComment]>.message(for: error))
        }
    }

    private func post() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        posting = true
        postError = nil
        defer { posting = false }
        do {
            try await api.postComment(rowId, stage, clipId.map { "[[clip:\($0)]]\n\(text)" } ?? text)
            draft = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } catch {
            postError = Loadable<Void>.message(for: error)
        }
    }

    private func setResolved(_ comment: StageComment) async {
        guard resolvingId == nil, var comments = state.value,
              let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        resolvingId = comment.id
        defer { resolvingId = nil }
        do {
            comments[index].resolvedAt = try await api.resolveComment(comment.id, comment.resolvedAt == nil)
            state = .loaded(comments)
        } catch {
            postError = Loadable<Void>.message(for: error)
        }
    }
}

/// A stage thread split the way the website shows it: the group thread (or one
/// clip's notes), with clip markers taken out, and how many notes sit on clips.
struct StageThread {
    let comments: [StageComment]
    let onClips: Int

    init(_ all: [StageComment], clipId: String?) {
        var kept: [StageComment] = []
        var clipNotes = 0
        for comment in all {
            let parsed = ClipComment.parse(comment.body)
            if parsed.clipId != nil { clipNotes += 1 }
            guard parsed.clipId == clipId else { continue }
            var clean = StageComment(id: comment.id, body: parsed.text, createdAt: comment.createdAt, author: comment.author)
            clean.reviewHref = comment.reviewHref
            clean.resolvedAt = comment.resolvedAt
            kept.append(clean)
        }
        comments = kept
        onClips = clipId == nil ? clipNotes : 0
    }
}

private struct CommentRow: View {
    let comment: StageComment
    let resolving: Bool
    let onToggleResolved: () -> Void
    let onOpenReview: (String) -> Void

    var body: some View {
        let resolved = comment.resolvedAt != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(comment.authorName).font(.lexend(14, .semibold)).foregroundStyle(Brand.foreground)
                if resolved { StatusTag(text: "Resolved", tone: .success) }
                Spacer()
                Text(comment.createdAt, format: .relative(presentation: .named))
                    .font(.small)
                    .foregroundStyle(Brand.muted)
            }
            Text(comment.body)
                .font(.bodyText)
                .foregroundStyle(resolved ? Brand.muted : Brand.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                if let href = comment.reviewHref {
                    Button { onOpenReview(href) } label: { Label("Open review", systemImage: "play.rectangle") }
                        .font(.lexend(14, .medium))
                        .foregroundStyle(Brand.green)
                        .frame(minHeight: 44)
                }
                Button(action: onToggleResolved) {
                    Label(resolved ? "Reopen" : "Mark resolved", systemImage: resolved ? "arrow.uturn.backward" : "checkmark")
                }
                .font(.lexend(14, .medium))
                .foregroundStyle(Brand.secondary)
                .frame(minHeight: 44)
                .disabled(resolving)
            }
        }
        .card(padding: 12)
        .accessibilityElement(children: .contain)
    }
}
