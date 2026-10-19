import XCTest
@testable import InFocusPortal

/// The native review: `GET api/media/<id>/review`, video posters, review links from stages and
/// notices, and the rules the review screen follows.
final class ReviewDetailTests: XCTestCase {
    static let json = #"""
    {"data":{"mediaId":"m1","projectId":"p1","projectName":"Club Fair","folderName":"Cuts","title":"Initial Cut Version 2",
      "workspaceRole":"REVIEWER","canUpdateApprovalStatus":false,"canManageQuickGrades":false,"currentUserId":"u-abby",
      "packageReview":{"rowId":"r1","kind":"initial-cut","stage":"ADVISER_REVIEW","canSubmitReview":true,"canApprove":true,
                       "canUnapprove":false,"canApproveAnyway":false,"awaitingRevisedInitialCut":false,"remainingExecutiveSignoffs":2},
      "assignedPeople":[{"userId":"u-abby","name":"Abby","email":"abby@example.edu"},{"userId":"u-otto","name":null,"email":"otto@example.edu"}],
      "currentVersionId":"v2",
      "versions":[
        {"id":"v2","versionNumber":2,"bunnyVideoId":"","sourceType":"VIDEO","status":"READY","approvalStatus":"IN_REVIEW",
         "approvedInStage":null,"airedAt":null,"playbackUrl":"https://drive.example.edu/v2.mp4?sig=x",
         "thumbnailUrl":"https://drive.example.edu/v2/poster.jpg?sig=x","imageUrl":null,"createdAt":"2026-10-02T00:00:00.000Z"},
        {"id":"v1","versionNumber":1,"bunnyVideoId":"b1","sourceType":"VIDEO","status":"READY","approvalStatus":"NEEDS_CHANGES",
         "approvedInStage":1,"airedAt":null,"playbackUrl":null,"thumbnailUrl":null,"imageUrl":null,"createdAt":"2026-10-01T00:00:00.000Z"}],
      "comments":[
        {"id":"c1","mediaVersionId":"v1","body":"Trim the intro.","authorId":"u-sage","authorName":"Sage","timeSeconds":4.5,
         "frameNumber":135,"xPct":null,"yPct":null,"targetType":"TIMECODE","createdAt":"2026-10-01T01:00:00.000Z","resolvedAt":null,"parentCommentId":null},
        {"id":"c2","mediaVersionId":"v2","body":"Love this shot.","authorId":"u-abby","authorName":"Abby","timeSeconds":12,
         "frameNumber":360,"xPct":40,"yPct":60,"targetType":"FRAME_PIN","createdAt":"2026-10-02T01:00:00.000Z","resolvedAt":null,"parentCommentId":null},
        {"id":"c3","mediaVersionId":"v2","body":"Thanks!","authorId":null,"authorName":"Guest Reviewer","timeSeconds":null,
         "frameNumber":null,"xPct":null,"yPct":null,"targetType":"TIMECODE","createdAt":"2026-10-02T02:00:00.000Z",
         "resolvedAt":"2026-10-02T03:00:00.000Z","parentCommentId":"c2"}],
      "allowComment":true,"isInitialCut":true,"canViewShareLinks":false}}
    """#

    static func detail() throws -> ReviewDetail {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<ReviewDetail>.self, from: Data(json.utf8)).data
    }

    func testDecodesTheReviewPayload() throws {
        let detail = try Self.detail()
        XCTAssertEqual(detail.projectName, "Club Fair")
        XCTAssertEqual(detail.workspaceRole, .reviewer)
        XCTAssertEqual(detail.currentVersionId, "v2")
        XCTAssertEqual(detail.versions.map(\.id), ["v2", "v1"])
        XCTAssertEqual(detail.latestVersion?.id, "v2")
        XCTAssertEqual(detail.versions[1].approvedInStage, 1)
        XCTAssertEqual(detail.versions[1].approvalStatus, .needsChanges)
        XCTAssertEqual(detail.assignees, ["Abby", "otto@example.edu"])
        XCTAssertEqual(detail.packageReview?.stage, "ADVISER_REVIEW")
        XCTAssertEqual(detail.packageReview?.remainingExecutiveSignoffs, 2)
        XCTAssertEqual(detail.packageReview?.hasDecision, true)
        XCTAssertTrue(detail.isInitialCut)

        XCTAssertEqual(detail.comments.count, 3)
        XCTAssertEqual(detail.comments[0].authorName, "Sage")
        XCTAssertEqual(detail.comments[0].timeSeconds, 4.5)
        XCTAssertEqual(detail.comments[1].targetType, .framePin)
        XCTAssertEqual(detail.comments[1].xPct, 40)
        XCTAssertEqual(detail.comments[2].timeSeconds, 0, "a null time reads as 0")
        XCTAssertEqual(detail.comments[2].parentCommentId, "c2")
        XCTAssertTrue(detail.comments[2].isResolved)

        let threads = ReviewLogic.threads(detail.comments, versionId: "v2")
        XCTAssertEqual(threads.map(\.id), ["c2"])
        XCTAssertEqual(threads.first?.replies.map(\.id), ["c3"])
    }

    func testPackageReviewWithoutOptionalFlags() throws {
        let review = try PortalJSON.decoder().decode(ReviewDetail.PackageReview.self, from: Data(#"""
        {"rowId":"r1","kind":"initial-cut","stage":"APPROVED","canSubmitReview":false,"canApprove":false}
        """#.utf8))
        XCTAssertFalse(review.hasDecision)
        XCTAssertNil(review.awaitingRevisedInitialCut)
    }

    func testVideoPostersAreAbsoluteURLsOnly() throws {
        let detail = try Self.detail()
        XCTAssertEqual(detail.versions[0].posterURL?.absoluteString, "https://drive.example.edu/v2/poster.jpg?sig=x")
        XCTAssertNil(detail.versions[1].posterURL, "still processing or no poster")
        let image = ReviewVersion(id: "v9", versionNumber: 1, sourceType: .image, status: .ready, approvalStatus: .inReview,
                                  createdAt: Date(), thumbnailUrl: "/api/media/m9/versions/v9/image")
        XCTAssertNil(image.posterURL, "images load with the session instead")
        XCTAssertNil(ReviewVersion.posterURL(from: "/api/media/m9/versions/v9/image"))
        XCTAssertNotNil(ReviewVersion.posterURL(from: "https://cdn.example.edu/b1/thumbnail.jpg"))
    }

    func testMediaPageRowsCarryThumbnails() throws {
        let page = try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<ReviewMediaPage>.self, from: Data(#"""
        {"data":{"items":[{"id":"m1","projectId":"p1","folderId":null,"title":"Interview","currentVersionId":"v1","deletedAt":null,
          "updatedAt":"2026-10-01T00:00:00.000Z","memberAssignments":[],"deletedBy":null,
          "currentVersion":{"id":"v1","versionNumber":1,"sourceType":"VIDEO","status":"READY","approvalStatus":"IN_REVIEW",
                            "createdAt":"2026-10-01T00:00:00.000Z","storageSizeBytes":1048576,"thumbnailUrl":"https://cdn.example.edu/b1/thumbnail.jpg"},
          "versions":[{"id":"v1","versionNumber":1,"sourceType":"VIDEO","status":"READY","approvalStatus":"IN_REVIEW","durationSeconds":61.5,
                       "createdAt":"2026-10-01T00:00:00.000Z","storageSizeBytes":1048576,"thumbnailUrl":"https://cdn.example.edu/b1/thumbnail.jpg",
                       "createdBy":{"name":"Abby","nickname":null,"email":"abby@example.edu"},"_count":{"comments":2}}]}],
          "totalCount":1,"page":1,"pageSize":40,"totalPages":1}}
        """#.utf8)).data
        let version = try XCTUnwrap(page.items.first?.currentVersion)
        XCTAssertEqual(version.posterURL?.host, "cdn.example.edu")
        XCTAssertEqual(version.commentCount, 2)
    }

    // MARK: Rules

    func testInitialCutsAreTitledByTheVersionOnScreen() throws {
        let detail = try Self.detail()
        XCTAssertEqual(ReviewLogic.title(detail, version: detail.versions[1]), "Initial Cut Version 1")
        XCTAssertEqual(ReviewLogic.title(detail, version: detail.versions[0]), "Initial Cut Version 2")
        let other = try ReviewStub.review("m1")
        XCTAssertEqual(ReviewLogic.title(other, version: other.versions.first), "Interview with the club president")
    }

    func testTappingACommentSeeks() throws {
        let comments = try Self.detail().comments
        XCTAssertEqual(ReviewLogic.seekTime(comments[0], isImage: false), 4.5)
        XCTAssertEqual(ReviewLogic.seekTime(comments[1], isImage: false), 12, "a pin on a video frame")
        XCTAssertNil(ReviewLogic.seekTime(comments[1], isImage: true), "a pin on an image")
        let general = ReviewComment(id: "g", mediaVersionId: "v2", authorId: nil, parentCommentId: nil, targetType: .general,
                                    timeSeconds: 0, xPct: nil, yPct: nil, body: "Nice", createdAt: Date(), resolvedAt: nil)
        XCTAssertNil(ReviewLogic.seekTime(general, isImage: false))
    }

    func testCommentPermissionsFollowRoleAndClosedReview() throws {
        let reply = try Self.detail().comments[2]
        let root = try Self.detail().comments[1]
        let open = ReviewLogic.CommentPermissions(canComment: true, role: .reviewer)
        XCTAssertTrue(open.canResolve(own: true))
        XCTAssertFalse(open.canResolve(own: false), "reviewers resolve only their own")
        XCTAssertTrue(open.canDelete(own: true))
        XCTAssertFalse(open.canDelete(own: false))
        XCTAssertTrue(open.canEdit(root, own: true))
        XCTAssertFalse(open.canEdit(root, own: false))
        XCTAssertTrue(ReviewLogic.CommentPermissions(canComment: true, role: .editor).canResolve(own: false))

        let closed = ReviewLogic.CommentPermissions(canComment: false, role: .ownerAdmin)
        XCTAssertFalse(closed.canResolve(own: true))
        XCTAssertFalse(closed.canDelete(own: true))
        XCTAssertFalse(closed.canEdit(root, own: true))
        XCTAssertTrue(closed.canEdit(reply, own: true), "own replies stay editable, like the web")
    }

    // MARK: Review links

    func testReviewLinksOpenTheNativeReview() {
        XCTAssertEqual(ReviewRoute.review(href: "/projects/p1/review/m1?bare=1&version=v2"),
                       .media(projectId: "p1", mediaId: "m1", versionId: "v2"))
        XCTAssertEqual(ReviewRoute.review(href: "projects/p1/review/m1"), .media(projectId: "p1", mediaId: "m1", versionId: nil))
        XCTAssertEqual(ReviewRoute.review(href: "https://portal.example.edu/projects/p1/review/m1?version=3"),
                       .media(projectId: "p1", mediaId: "m1", versionId: "3"))
        XCTAssertNil(ReviewRoute.review(href: "/projects/p1"), "a project link isn't a review")
        XCTAssertNil(ReviewRoute.review(href: "/groups/r1/initial-cut"))
    }
}

/// Loading the review screen's model from the Portal's review payload.
@MainActor
final class ReviewModelTests: XCTestCase {
    private func api(_ detail: ReviewDetail, asked: @escaping @Sendable (String?) -> Void = { _ in }) -> ReviewAPI {
        var api = ReviewAPI.stub
        api.review = { _, version in
            asked(version)
            return detail
        }
        return api
    }

    func testLoadsEveryCommentAndThePortalsVersion() async throws {
        let detail = try ReviewDetailTests.detail()
        let model = ReviewModel(projectId: "p1", mediaId: "m1", versionId: nil)
        await model.load(api(detail))
        XCTAssertEqual(model.version?.id, "v2")
        XCTAssertEqual(model.comments.count, 3)
        XCTAssertEqual(model.threads.map(\.id), ["c2"])
        XCTAssertEqual(model.title, "Initial Cut Version 2")
        XCTAssertTrue(model.isOwn(detail.comments[1]), "written by currentUserId")
        XCTAssertFalse(model.isOwn(detail.comments[2]), "a guest's reply")

        model.select(detail.versions[1])
        XCTAssertEqual(model.threads.map(\.id), ["c1"], "switching versions needs no new request")
        XCTAssertEqual(model.title, "Initial Cut Version 1")
    }

    func testAVersionNumberFromALinkTakesThePortalsPick() async throws {
        let detail = try ReviewDetailTests.detail()
        let asked = LockedValue<String?>(nil)
        let model = ReviewModel(projectId: "p1", mediaId: "m1", versionId: "2")
        await model.load(api(detail) { asked.set($0) })
        XCTAssertEqual(asked.get(), "2", "the link's version goes to the Portal as is")
        XCTAssertEqual(model.version?.id, "v2")
    }

    func testNoAccessShowsNotAvailable() async {
        var api = ReviewAPI.stub
        api.review = { _, _ in throw PortalError.notFound }
        let model = ReviewModel(projectId: "p1", mediaId: "m1", versionId: nil)
        await model.load(api)
        guard case .failed(let message) = model.state else { return XCTFail("expected a failure") }
        XCTAssertEqual(message, "This item isn't available to you.")
    }
}

/// A value a `@Sendable` closure can write.
private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

/// The review and poster requests the live API sends.
final class ReviewDetailRequestTests: XCTestCase {
    private var api: ReviewAPI!

    override func setUp() {
        super.setUp()
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        api = .live(PortalClient(portal: URL(string: "https://portal.example.edu")!, session: URLSession(configuration: config),
                                 cookies: { [] }))
    }

    func testReviewRequest() async throws {
        StubProtocol.handler = { _ in (200, Data(ReviewDetailTests.json.utf8)) }
        let detail = try await api.review("m1", "v2")
        XCTAssertEqual(detail.mediaId, "m1")
        let url = try XCTUnwrap(StubProtocol.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/media/m1/review")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "version", value: "v2")])

        _ = try await api.review("m1", nil)
        XCTAssertNil(StubProtocol.lastRequest?.url?.query)
    }

    func testPosterRequest() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"thumbnailUrl":"https://drive.example.edu/v1/poster.jpg?sig=y"}}"#.utf8)) }
        let poster = try await api.poster("m1", "v1")
        XCTAssertEqual(poster, "https://drive.example.edu/v1/poster.jpg?sig=y")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/media/m1/versions/v1/poster")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "GET")

        StubProtocol.handler = { _ in (200, Data(#"{"data":{"thumbnailUrl":null}}"#.utf8)) }
        let processing = try await api.poster("m1", "v1")
        XCTAssertNil(processing)
    }
}
