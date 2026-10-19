import UIKit

/// Fictional data for the App Review sample app (`SampleMode`) and screenshots: the
/// sample workspace's project with photos and comments. Nothing is sent anywhere;
/// changes show "Sample app: changes aren't saved."
extension ReviewAPI {
    static let stub = ReviewAPI(
        workspaces: { ReviewStub.workspaces },
        roles: { [ReviewWorkspaceAccess(id: "w1", name: "Sample workspace", role: .editor, projectCount: 1)] },
        shell: { _, mediaId in ReviewStub.shell(mediaId: mediaId) },
        media: { _, query in ReviewStub.page(query) },
        playback: { _, _ in throw PortalError.sampleApp },
        image: { mediaId, _ in ReviewStub.image(for: mediaId) },
        review: { mediaId, _ in try ReviewStub.review(mediaId) },
        poster: { _, _ in nil },
        comment: { new in
            SampleMode.notSaved()
            return ReviewComment(id: "local-\(UUID().uuidString)", mediaVersionId: new.mediaVersionId, authorId: "u-me",
                                 parentCommentId: nil, targetType: new.targetType, timeSeconds: new.timeSeconds ?? 0,
                                 xPct: new.xPct, yPct: new.yPct, body: new.body, createdAt: Date(), resolvedAt: nil, authorName: "You")
        },
        reply: { parentId, body in
            SampleMode.notSaved()
            let parent = ReviewStub.comments.first { $0.id == parentId }
            return ReviewComment(id: "local-\(UUID().uuidString)", mediaVersionId: parent?.mediaVersionId ?? "", authorId: "u-me",
                                 parentCommentId: parentId, targetType: parent?.targetType ?? .general,
                                 timeSeconds: parent?.timeSeconds ?? 0, xPct: parent?.xPct, yPct: parent?.yPct, body: body,
                                 createdAt: Date(), resolvedAt: nil, authorName: "You")
        },
        setResolved: { _, _ in SampleMode.notSaved() },
        editComment: { _, _ in SampleMode.notSaved() },
        deleteComment: { _ in SampleMode.notSaved() },
        setApproval: { _, _, _, _ in SampleMode.notSaved() },
        rename: { _, _ in SampleMode.notSaved() },
        deleteMedia: { _ in SampleMode.notSaved() },
        restoreMedia: { _ in SampleMode.notSaved() },
        deleteForever: { _ in SampleMode.notSaved() },
        createFolder: { _, _ in SampleMode.notSaved() },
        createProject: { _, _ in throw PortalError.sampleApp },
        deleteProject: { _ in SampleMode.notSaved() },
        guestLinks: { _ in [] },
        createGuestLink: { _ in SampleMode.notSaved() },
        revokeGuestLink: { _ in SampleMode.notSaved() },
        startUpload: { _ in throw PortalError.sampleApp },
        finishUpload: { _, _ in SampleMode.notSaved() },
        uploadImage: { _, _, _, _ in SampleMode.notSaved() }
    )
}

enum ReviewStub {
    static let now = Date()
    static func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }

    static let sage = ReviewPerson(id: "u-sage", name: "Sage", email: "sage@example.edu")
    static let abby = ReviewPerson(id: "u-abby", name: "Abby", email: "abby@example.edu")

    static let workspaces = [WorkspaceSummary(id: "w1", name: "Sample workspace", projects: [
        ProjectSummary(id: "p1", name: "Sample package: Club Fair", updatedAt: ago(hours: 24), mediaCount: 3),
    ])]

    static let folders = [ReviewFolder(id: "f-photos", name: "Photos", activeMediaCount: 1)]

    /// Which version each sample item shows.
    static let versionIds = ["m-booth": "v-booth", "m-quad": "v-quad", "m1": "v-interview"]

    static let items: [ReviewMedia] = [
        item("m-booth", "Club Fair booth", folder: nil, .image, hours: 3),
        item("m1", "Interview with the club president", folder: nil, .video, hours: 6, duration: 94),
        item("m-quad", "Quad at lunch", folder: "f-photos", .image, hours: 30),
    ]

    static func item(_ id: String, _ title: String, folder: String?, _ type: ReviewSourceType, hours: Double,
                     duration: Double? = nil) -> ReviewMedia {
        let versionId = versionIds[id] ?? "v-\(id)"
        let count = comments.filter { $0.mediaVersionId == versionId }.count
        return ReviewMedia(id: id, title: title, folderId: folder, currentVersionId: versionId, deletedAt: nil, updatedAt: ago(hours: hours),
                           versions: [ReviewVersion(id: versionId, versionNumber: 1, sourceType: type, status: .ready,
                                                    approvalStatus: .inReview, durationSeconds: duration, createdAt: ago(hours: hours),
                                                    createdBy: abby, commentCount: count)],
                           memberAssignments: [.init(user: abby)], deletedBy: nil)
    }

    static let comments = [
        ReviewComment(id: "c1", mediaVersionId: "v-booth", authorId: "u-sage", parentCommentId: nil, targetType: .framePin,
                      timeSeconds: 0, xPct: 32, yPct: 40, body: "Great framing on the banner. Can we get one with the crowd too?",
                      createdAt: ago(hours: 2), resolvedAt: nil, authorName: "Sage"),
        ReviewComment(id: "c2", mediaVersionId: "v-booth", authorId: "u-abby", parentCommentId: "c1", targetType: .framePin,
                      timeSeconds: 0, xPct: 32, yPct: 40, body: "Yes, I shot a wide one at lunch.",
                      createdAt: ago(hours: 1), resolvedAt: nil, authorName: "Abby"),
        ReviewComment(id: "c3", mediaVersionId: "v-booth", authorId: "u-sage", parentCommentId: nil, targetType: .general,
                      timeSeconds: 0, xPct: nil, yPct: nil, body: "Use this one for the thumbnail.",
                      createdAt: ago(hours: 1.5), resolvedAt: ago(hours: 0.5), authorName: "Sage"),
        ReviewComment(id: "c4", mediaVersionId: "v-interview", authorId: "u-sage", parentCommentId: nil, targetType: .timecode,
                      timeSeconds: 12, xPct: nil, yPct: nil, body: "Start the interview here and trim the warm-up.",
                      createdAt: ago(hours: 4), resolvedAt: nil, authorName: "Sage"),
    ]

    /// The review of one sample item: its comments, as the sample account (an editor) sees it.
    static func review(_ mediaId: String) throws -> ReviewDetail {
        guard let item = items.first(where: { $0.id == mediaId }) else { throw PortalError.notFound }
        let versionId = item.currentVersionId ?? ""
        return ReviewDetail(mediaId: item.id, projectId: "p1", projectName: "Sample package: Club Fair",
                            folderName: folders.first { $0.id == item.folderId }?.name, title: item.title, workspaceRole: .editor,
                            canUpdateApprovalStatus: false, currentUserId: "u-me", packageReview: nil,
                            assignedPeople: [.init(userId: "u-abby", name: "Abby", email: "abby@example.edu")],
                            currentVersionId: versionId, versions: item.versions,
                            comments: comments.filter { $0.mediaVersionId == versionId },
                            allowComment: true, isInitialCut: false, canViewShareLinks: false)
    }

    static func shell(mediaId: String?) -> ReviewProjectShell {
        let asset = mediaId.flatMap { id in items.first { $0.id == id } }
        return ReviewProjectShell(projectId: "p1", projectName: "Sample package: Club Fair",
                                  workspace: .init(id: "w1", name: "Sample workspace"), folders: folders, assetCount: items.count,
                                  currentAsset: asset.map { .init(id: $0.id, title: $0.title, folderId: $0.folderId, folderName: nil) },
                                  canViewShareLinks: false)
    }

    static func page(_ query: ReviewMediaQuery) -> ReviewMediaPage {
        let shown = query.scope == .deleted ? [] : items.filter { $0.folderId == query.folderId }
        return ReviewMediaPage(items: shown, totalCount: shown.count, page: 1, pageSize: 40, totalPages: 1)
    }

    /// A flat, drawn stand-in for a photo (no real images in the sample app).
    static func image(for mediaId: String) -> Data {
        let size = CGSize(width: 1200, height: 800)
        let title = items.first { $0.id == mediaId }?.title ?? "Sample photo"
        let image = UIGraphicsImageRenderer(size: size).image { context in
            Brand.uiFill.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 1, alpha: 0.12).setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.62, width: size.width, height: size.height * 0.38))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 64, weight: .semibold),
                                                             .foregroundColor: UIColor.white]
            NSString(string: title).draw(at: CGPoint(x: 64, y: 96), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}
