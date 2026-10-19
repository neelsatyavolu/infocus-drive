import Foundation
import Observation

/// One item under review: its versions and every version's comments (one Portal call), and
/// every change (comment, reply, resolve, edit, delete, approval status).
@MainActor @Observable
final class ReviewModel {
    let projectId: String
    let mediaId: String
    private(set) var state: Loadable<ReviewDetail> = .idle
    private(set) var versionId: String?
    private(set) var comments: [ReviewComment] = []
    private(set) var busy = false
    var actionError: String?

    init(projectId: String, mediaId: String, versionId: String?) {
        self.projectId = projectId
        self.mediaId = mediaId
        self.versionId = versionId
    }

    var detail: ReviewDetail? { state.value }
    var role: ReviewWorkspaceRole? { detail?.workspaceRole }
    var title: String? { detail.map { ReviewLogic.title($0, version: version) } }

    var version: ReviewVersion? {
        guard let detail else { return nil }
        return detail.versions.first { $0.id == versionId }
            ?? detail.versions.first { $0.id == detail.currentVersionId }
            ?? detail.latestVersion
    }

    var permissions: ReviewLogic.CommentPermissions {
        ReviewLogic.CommentPermissions(canComment: detail?.allowComment ?? false, role: role)
    }

    var threads: [ReviewLogic.Thread] {
        guard let version else { return [] }
        return ReviewLogic.threads(comments, versionId: version.id)
    }

    /// Written by the signed-in person (the Portal's `currentUserId`).
    func isOwn(_ comment: ReviewComment) -> Bool {
        guard let me = detail?.currentUserId, let author = comment.authorId else { return false }
        return me == author
    }

    func load(_ api: ReviewAPI) async {
        if state.value == nil { state = .loading }
        do {
            let detail = try await api.review(mediaId, versionId)
            state = .loaded(detail)
            comments = detail.comments
            // A version number from a link, or a version that's gone: take the one the Portal picked.
            if versionId == nil || !detail.versions.contains(where: { $0.id == versionId }) {
                versionId = detail.currentVersionId.isEmpty ? detail.latestVersion?.id : detail.currentVersionId
            }
        } catch PortalError.forbidden, PortalError.notFound {
            state = .failed("This item isn't available to you.")
        } catch {
            if state.value == nil { state = .failed(Loadable<ReviewDetail>.message(for: error)) }
        }
    }

    func select(_ version: ReviewVersion) { versionId = version.id }

    // MARK: Comments

    /// A comment on the current version: at `time` (video), at a pin (image), or general.
    @discardableResult
    func post(_ raw: String, time: Double?, pin: CGPoint?, api: ReviewAPI) async -> Bool {
        guard let version else { return false }
        guard let body = ReviewLogic.cleanComment(raw) else {
            actionError = "Comments are 1 to \(ReviewLogic.commentLimit) characters."
            return false
        }
        var new = NewReviewComment(mediaVersionId: version.id, targetType: .general, body: body)
        if let pin {
            new = NewReviewComment(mediaVersionId: version.id, targetType: .framePin, timeSeconds: 0, frameNumber: 0,
                                   xPct: Double(pin.x), yPct: Double(pin.y), body: body)
        } else if let time {
            new = NewReviewComment(mediaVersionId: version.id, targetType: .timecode, timeSeconds: max(0, time),
                                   frameNumber: ReviewLogic.frameNumber(time), body: body)
        }
        return await run {
            var created = try await api.comment(new)
            created.authorName = created.authorName ?? "You"
            add(created)
        }
    }

    @discardableResult
    func reply(to thread: ReviewLogic.Thread, _ raw: String, api: ReviewAPI) async -> Bool {
        guard let body = ReviewLogic.cleanComment(raw) else {
            actionError = "Replies are 1 to \(ReviewLogic.commentLimit) characters."
            return false
        }
        return await run {
            var created = try await api.reply(thread.root.id, body)
            created.authorName = created.authorName ?? "You"
            add(created)
        }
    }

    func toggleResolved(_ comment: ReviewComment, api: ReviewAPI) async {
        let resolve = !comment.isResolved
        await run {
            try await api.setResolved(comment.id, resolve)
            update(comment.id) { $0.resolvedAt = resolve ? Date() : nil }
        }
    }

    @discardableResult
    func edit(_ comment: ReviewComment, to raw: String, api: ReviewAPI) async -> Bool {
        guard let body = ReviewLogic.cleanComment(raw) else {
            actionError = "Comments are 1 to \(ReviewLogic.commentLimit) characters."
            return false
        }
        return await run {
            try await api.editComment(comment.id, body)
            update(comment.id) { $0.body = body }
        }
    }

    /// Deleting a comment deletes its replies too (the Portal cascades).
    func delete(_ comment: ReviewComment, api: ReviewAPI) async {
        await run {
            try await api.deleteComment(comment.id)
            comments = comments.filter { $0.id != comment.id && $0.parentCommentId != comment.id }
        }
    }

    // MARK: Approval

    func setApproval(_ status: ReviewApproval, airedAt: Date?, api: ReviewAPI) async {
        guard let version else { return }
        await run {
            try await api.setApproval(mediaId, version.id, status, airedAt)
            await load(api)
        }
    }

    // MARK: Plumbing

    private func add(_ comment: ReviewComment) {
        comments.append(comment)
    }

    private func update(_ id: String, _ change: (inout ReviewComment) -> Void) {
        comments = comments.map { comment in
            guard comment.id == id else { return comment }
            var changed = comment
            change(&changed)
            return changed
        }
    }

    @discardableResult
    private func run(_ action: () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await action()
            return true
        } catch {
            actionError = Loadable<Void>.message(for: error)
            return false
        }
    }
}
