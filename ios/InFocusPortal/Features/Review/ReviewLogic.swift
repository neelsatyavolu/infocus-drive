import Foundation

/// The review rules ported from the Portal (`src/lib/timecode.ts`, `src/lib/rbac.ts`,
/// `src/lib/approval.ts`), kept free of UI so tests can pin them down.
enum ReviewLogic {
    /// Frames per second the web review uses for frame numbers (`DEFAULT_REVIEW_FPS`).
    static let fps = 30.0
    static let commentLimit = 2_000
    static let titleLimit = 150

    /// `00:01:05` (hours always shown, like the web).
    static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    static func frameNumber(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return max(0, Int((seconds * fps).rounded()))
    }

    /// The approval moves the Portal allows from a status (`isApprovalTransitionAllowed`).
    static func transitions(from status: ReviewApproval) -> [ReviewApproval] {
        switch status {
        case .inReview: [.needsChanges, .approved]
        case .needsChanges: [.inReview, .approved]
        case .approved: [.needsChanges, .aired]
        case .aired: [.needsChanges]
        }
    }

    static func label(_ status: ReviewApproval) -> String {
        switch status {
        case .inReview: "In review"
        case .needsChanges: "Needs changes"
        case .approved: "Approved"
        case .aired: "Aired"
        }
    }

    static func label(_ status: ReviewMediaStatus) -> String? {
        switch status {
        case .ready: nil
        case .uploading: "Uploading"
        case .processing: "Processing"
        case .failed: "Failed"
        }
    }

    /// A clean title the Portal accepts (1–150 characters), or nil.
    static func cleanTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(titleLimit))
    }

    static func cleanComment(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > commentLimit ? nil : trimmed
    }

    /// Where a guest link opens (`/g/<token>` on the Portal).
    static func guestURL(token: String, portal: URL) -> URL {
        portal.appendingPathComponent("g").appendingPathComponent(token)
    }

    /// The web review page for a version (the fallback for what the app can't show).
    static func reviewPath(projectId: String, mediaId: String, versionId: String?) -> String {
        let base = "projects/\(projectId)/review/\(mediaId)"
        return versionId.map { "\(base)?version=\($0)" } ?? base
    }

    /// The heading: Initial Cuts are titled by the version on screen (`initialCutVersionTitle`).
    static func title(_ detail: ReviewDetail, version: ReviewVersion?) -> String {
        guard detail.isInitialCut else { return detail.title }
        return "Initial Cut Version \(max(1, version?.versionNumber ?? 1))"
    }

    /// Where tapping a comment moves the video: timecoded notes and pins on a video frame.
    static func seekTime(_ comment: ReviewComment, isImage: Bool) -> Double? {
        switch comment.targetType {
        case .timecode: comment.timeSeconds
        case .framePin: isImage ? nil : comment.timeSeconds
        case .general: nil
        }
    }

    // MARK: Threads

    struct Thread: Identifiable, Hashable {
        var root: ReviewComment
        var replies: [ReviewComment]
        var id: String { root.id }
    }

    /// Roots with their replies; timeline comments by time, then general ones, oldest first.
    static func threads(_ comments: [ReviewComment], versionId: String) -> [Thread] {
        let mine = comments.filter { $0.mediaVersionId == versionId }
        let roots = mine.filter { !$0.isReply }
        return roots
            .map { root in
                Thread(root: root, replies: mine.filter { $0.parentCommentId == root.id }.sorted { $0.createdAt < $1.createdAt })
            }
            .sorted { lhs, rhs in
                let lGeneral = lhs.root.targetType == .general, rGeneral = rhs.root.targetType == .general
                if lGeneral != rGeneral { return !lGeneral }
                if lhs.root.timeSeconds != rhs.root.timeSeconds { return lhs.root.timeSeconds < rhs.root.timeSeconds }
                return lhs.root.createdAt < rhs.root.createdAt
            }
    }

    // MARK: Who can do what (the server checks again)

    /// Rename, delete, restore and change folders (`canManageProjectMedia`).
    static func canManageMedia(role: ReviewWorkspaceRole?, isProducer: Bool) -> Bool {
        isProducer || (role?.atLeast(.editor) ?? false)
    }

    /// Rename needs an editor membership (`PATCH api/media/<id>`).
    static func canRename(role: ReviewWorkspaceRole?) -> Bool {
        role?.atLeast(.editor) ?? false
    }

    /// Resolve: editors any comment, reviewers their own (`canResolveComment`).
    static func canResolve(role: ReviewWorkspaceRole?, own: Bool) -> Bool {
        (role?.atLeast(.editor) ?? false) || own
    }

    /// Delete: your own comment, or any as an editor or owner.
    static func canDelete(role: ReviewWorkspaceRole?, own: Bool) -> Bool {
        own || (role?.atLeast(.editor) ?? false)
    }

    /// What this person may do with comments on the review page (`ThreadPermissions`): nothing
    /// but edit their own replies once an Initial Cut's review is closed (`allowComment` false).
    struct CommentPermissions: Hashable {
        let canComment: Bool
        let role: ReviewWorkspaceRole?

        func canResolve(own: Bool) -> Bool { canComment && ReviewLogic.canResolve(role: role, own: own) }
        func canDelete(own: Bool) -> Bool { canComment && ReviewLogic.canDelete(role: role, own: own) }
        func canEdit(_ comment: ReviewComment, own: Bool) -> Bool { own && (canComment || comment.isReply) }
    }

    /// Guest links: owners of the workspace, on projects they belong to directly.
    static func canShare(role: ReviewWorkspaceRole?, shell: ReviewProjectShell) -> Bool {
        role == .ownerAdmin && shell.canViewShareLinks
    }
}
