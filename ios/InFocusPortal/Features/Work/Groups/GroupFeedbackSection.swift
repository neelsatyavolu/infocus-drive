import SwiftUI

/// A group stage's feedback thread for producers (the website's `StageComments` panel):
/// newest first, Resolved notes marked, "Open review" on review notices, and a composer
/// for producers who may act. With `clip`, only that clip's notes, and new notes go on it.
struct GroupFeedbackSection: View {
    let rowId: String
    let stage: String
    let canPost: Bool
    var clip: StageMedia?
    var title = "Feedback"
    var composerHint: String?
    /// After a note posts (A-roll/B-roll notes ask the group for changes, which moves the status).
    var onPosted: (() -> Void)?
    /// Bump to fetch the thread again (after a decision that adds a note).
    var refreshKey = 0

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session
    @State private var state: Loadable<[GroupNote]> = .idle
    @State private var draft = ""
    @State private var posting = false
    @State private var postError: String?
    @State private var resolving: String?
    @State private var reportTarget: ReportTarget?

    private var service: GroupReviewService { GroupReviewService(client: client) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            switch state {
            case .idle, .loading:
                Skeleton(height: 60)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
            case .loaded(let notes):
                let shown = notes.filter { $0.clipId == clip?.id }
                if shown.isEmpty {
                    Text(canPost ? "No feedback yet. Leave the first note." : "No feedback yet.")
                        .font(.small)
                        .foregroundStyle(Brand.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                } else {
                    let onClips = clip == nil ? notes.filter { $0.clipId != nil }.count : 0
                    if onClips > 0 {
                        Text("\(onClips) more note\(onClips == 1 ? "" : "s") on clips. Open a clip to read them.")
                            .font(.small).foregroundStyle(Brand.muted)
                    }
                    ForEach(shown) { note in noteRow(note) }
                }
            }
            if canPost { composer }
        }
        .task(id: "\(rowId)/\(stage)/\(refreshKey)") { await load() }
        .sheet(item: $reportTarget) { ReportSheet(target: $0) }
    }

    private func noteRow(_ note: GroupNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(note.authorName).font(.lexend(14, .semibold)).foregroundStyle(Brand.foreground)
                if note.resolvedAt != nil { StatusTag(text: "Resolved", tone: .success) }
                Spacer()
                Text(note.createdAt, format: .relative(presentation: .named))
                    .font(.small)
                    .foregroundStyle(Brand.muted)
            }
            Text(note.text)
                .font(.bodyText)
                .foregroundStyle(note.resolvedAt == nil ? Brand.secondary : Brand.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                if let href = note.reviewHref {
                    Button("Open review") { router.openPortal(href, title: "Review") }
                        .font(.lexend(14, .medium))
                        .foregroundStyle(Brand.green)
                        .frame(minHeight: 44)
                        .hiddenInSampleApp()
                }
                if canPost {
                    Button(note.resolvedAt == nil ? "Mark resolved" : "Reopen") { Task { await setResolved(note) } }
                        .font(.lexend(14, .medium))
                        .foregroundStyle(Brand.muted)
                        .frame(minHeight: 44)
                        .disabled(resolving != nil)
                }
            }
        }
        .card(padding: 12)
        .contextMenu {
            if !isMine(note) {
                Button("Report comment", systemImage: "flag") {
                    reportTarget = ReportTarget(report: .comment(note.id), authorName: note.authorName, excerpt: note.text)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(clip == nil ? "Write feedback…" : "Note on this clip…", text: $draft, axis: .vertical)
                .font(.bodyText)
                .lineLimit(2...6)
                .padding(12)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
            if let composerHint {
                Text(composerHint).font(.small).foregroundStyle(Brand.muted)
            }
            if draft.count > GroupReviewLogic.noteMax {
                Text("Keep it to \(GroupReviewLogic.noteMax) characters.").font(.small).foregroundStyle(Brand.danger)
            }
            if let postError {
                Label(postError, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
            }
            Button(posting ? "Posting…" : "Post feedback") { Task { await post() } }
                .buttonStyle(.brandSecondary)
                .disabled(posting || trimmed.isEmpty || draft.count > GroupReviewLogic.noteMax)
        }
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func isMine(_ note: GroupNote) -> Bool {
        guard let mine = session.user?.email.lowercased(), let author = note.author.email?.lowercased() else { return false }
        return mine == author
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await service.notes(rowId: rowId, stage: stage))
        } catch PortalError.forbidden {
            state = .loaded([])
        } catch {
            if state.value == nil { state = .failed(Loadable<[GroupNote]>.message(for: error)) }
        }
    }

    private func post() async {
        guard !trimmed.isEmpty else { return }
        posting = true
        postError = nil
        defer { posting = false }
        do {
            try await service.postNote(rowId: rowId, stage: stage, body: trimmed, clipId: clip?.id)
            draft = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
            onPosted?()
        } catch {
            postError = Loadable<Void>.message(for: error)
        }
    }

    private func setResolved(_ note: GroupNote) async {
        resolving = note.id
        defer { resolving = nil }
        do {
            try await service.setResolved(noteId: note.id, resolved: note.resolvedAt == nil)
            await load()
        } catch {
            postError = Loadable<Void>.message(for: error)
        }
    }
}
