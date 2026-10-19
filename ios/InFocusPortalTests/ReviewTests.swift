import XCTest
@testable import InFocusPortal

/// Workspaces, projects and media review: decoding the Portal's shapes, the deep links,
/// the review rules, and the requests the live API sends.
final class ReviewDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
    }

    func testDecodesWorkspaceRoles() throws {
        let rows = try decode([ReviewWorkspaceAccess].self, #"""
        {"data":[{"id":"w1","name":"Sample","slug":"sample","role":"OWNER_ADMIN","visibility":"ALL_MEMBERS","projectCount":3,
                  "createdAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-02T00:00:00.000Z"}]}
        """#)
        XCTAssertEqual(rows.first?.role, .ownerAdmin)
        XCTAssertEqual(rows.first?.projectCount, 3)
        XCTAssertTrue(ReviewWorkspaceRole.editor.atLeast(.reviewer))
        XCTAssertFalse(ReviewWorkspaceRole.reviewer.atLeast(.editor))
    }

    func testDecodesHomeWorkspacesOnly() throws {
        let home = try decode(ReviewHomeWorkspaces.self, #"""
        {"data":{"upNext":null,"activity":[],"snapshot":null,
                 "workspaces":[{"id":"w1","name":"Sample","projects":[{"id":"p1","name":"Club Fair","updatedAt":"2026-10-01T00:00:00.000Z","mediaCount":2}]}]}}
        """#)
        XCTAssertEqual(home.workspaces.first?.projects.first?.id, "p1")
    }

    func testDecodesProjectShell() throws {
        let shell = try decode(ReviewProjectShell.self, #"""
        {"data":{"projectId":"p1","projectName":"Club Fair","workspace":{"id":"w1","name":"Sample"},
                 "folders":[{"id":"f1","name":"Photos","activeMediaCount":4}],"assetCount":9,
                 "currentAsset":{"id":"m1","title":"Booth","folderId":"f1","folderName":"Photos"},"canViewShareLinks":true}}
        """#)
        XCTAssertEqual(shell.folders.first?.activeMediaCount, 4)
        XCTAssertEqual(shell.currentAsset?.folderId, "f1")
        XCTAssertTrue(shell.canViewShareLinks)
        let bare = try decode(ReviewProjectShell.self, #"""
        {"data":{"projectId":"p1","projectName":"Club Fair","workspace":{"id":"w1","name":"Sample"},"folders":[],
                 "assetCount":0,"currentAsset":null,"canViewShareLinks":false}}
        """#)
        XCTAssertNil(bare.currentAsset)
    }

    /// The raw Prisma rows `getProjectMediaPage` returns, with `_count.comments` per version.
    func testDecodesAMediaPage() throws {
        let page = try decode(ReviewMediaPage.self, #"""
        {"data":{"items":[{"id":"m1","projectId":"p1","folderId":null,"title":"Interview","createdById":"u1","deletedById":null,
            "deletedAt":null,"currentVersionId":"v2","createdAt":"2026-10-01T00:00:00.000Z","updatedAt":"2026-10-02T00:00:00Z",
            "folder":null,"memberAssignments":[{"user":{"id":"u-abby","name":"Abby","nickname":null,"email":"abby@example.edu"}}],
            "deletedBy":null,"currentVersion":{"id":"v2"},
            "versions":[
              {"id":"v2","mediaItemId":"m1","versionNumber":2,"sourceType":"VIDEO","status":"READY","approvalStatus":"NEEDS_CHANGES",
               "airedAt":null,"durationSeconds":94.5,"createdAt":"2026-10-02T00:00:00.000Z",
               "createdBy":{"name":"Otto","nickname":null,"email":"otto@example.edu"},"_count":{"comments":3}},
              {"id":"v1","mediaItemId":"m1","versionNumber":1,"sourceType":"VIDEO","status":"READY","approvalStatus":"IN_REVIEW",
               "airedAt":null,"durationSeconds":90,"createdAt":"2026-10-01T00:00:00.000Z","createdBy":null,"_count":{"comments":0}}]},
          {"id":"m2","projectId":"p1","folderId":"f1","title":"Booth","deletedAt":"2026-10-03T00:00:00.000Z","currentVersionId":null,
            "updatedAt":"2026-10-03T00:00:00.000Z","deletedBy":{"name":"Sage","nickname":null,"email":"sage@example.edu"},
            "versions":[{"id":"v3","versionNumber":1,"sourceType":"IMAGE","status":"MYSTERY","approvalStatus":"AIRED",
               "airedAt":"2026-10-03T00:00:00.000Z","createdAt":"2026-10-03T00:00:00.000Z"}]}],
          "totalCount":2,"page":1,"pageSize":40,"totalPages":1}}
        """#)
        XCTAssertEqual(page.items.count, 2)
        let video = page.items[0]
        XCTAssertEqual(video.currentVersion?.id, "v2")
        XCTAssertEqual(video.currentVersion?.commentCount, 3)
        XCTAssertEqual(video.currentVersion?.approvalStatus, .needsChanges)
        XCTAssertEqual(video.currentVersion?.durationSeconds, 94.5)
        XCTAssertEqual(video.assignees, ["Abby"])
        XCTAssertFalse(video.isDeleted)
        let image = page.items[1]
        XCTAssertTrue(image.isDeleted)
        XCTAssertEqual(image.deletedBy?.label, "Sage")
        XCTAssertEqual(image.currentVersion?.id, "v3", "no current version falls back to the newest")
        XCTAssertTrue(image.currentVersion?.isImage == true)
        XCTAssertEqual(image.currentVersion?.status, .processing, "an unknown status doesn't break the page")
        XCTAssertEqual(image.currentVersion?.commentCount, 0)
    }

    func testDecodesPlaybackCommentsAndLinks() throws {
        let token = try decode(ReviewPlaybackToken.self, #"""
        {"data":{"playbackUrl":"https://drive.example.edu/v/abc.mp4?sig=1","provider":"NAS","nasPath":"x","expiresAt":1790000000}}
        """#)
        XCTAssertEqual(token.playbackUrl.host, "drive.example.edu")

        let comment = try decode(ReviewComment.self, #"""
        {"data":{"id":"c1","mediaVersionId":"v1","authorId":"u1","parentCommentId":null,"targetType":"TIMECODE","timeSeconds":12.5,
                 "frameNumber":375,"xPct":null,"yPct":null,"body":"Trim here","resolvedAt":null,"resolvedById":null,
                 "createdAt":"2026-10-01T00:00:00.000Z","updatedAt":"2026-10-01T00:00:00.000Z","mentions":[]}}
        """#)
        XCTAssertEqual(comment.targetType, .timecode)
        XCTAssertEqual(comment.timeSeconds, 12.5)
        XCTAssertFalse(comment.isResolved)
        XCTAssertNil(comment.authorName)

        let links = try decode([ReviewGuestLink].self, #"""
        {"data":[{"id":"g1","token":"tok-abc","permission":"COMMENT","expiresAt":null,"revokedAt":null,"createdAt":"2026-10-01T00:00:00.000Z"},
                 {"id":"g2","token":"tok-def","permission":"VIEW","expiresAt":"2026-10-02T00:00:00.000Z","revokedAt":null,"createdAt":"2026-10-01T00:00:00.000Z"},
                 {"id":"g3","token":"tok-ghi","permission":"VIEW","expiresAt":null,"revokedAt":"2026-10-02T00:00:00.000Z","createdAt":"2026-10-01T00:00:00.000Z"}]}
        """#)
        let now = PortalJSON.date(from: "2026-10-05T00:00:00Z")!
        XCTAssertEqual(links.map { $0.isActive(now: now) }, [true, false, false])
        XCTAssertEqual(links[1].permission, .view)
    }

    func testDecodesUploadTickets() throws {
        let nas = try decode(ReviewUploadTicket.self, #"""
        {"data":{"media":{"id":"m9","title":"Clip"},"version":{"id":"v9","versionNumber":1},
                 "upload":{"provider":"NAS","uploadUrl":"https://drive.example.edu/upload","path":"Projects/Clip/v1/clip.mov","token":"t",
                           "expiresAt":"2026-10-01T00:00:00.000Z","videoId":"nas:1","libraryId":"nas","signature":"s"}}}
        """#)
        XCTAssertEqual(nas.media.id, "m9")
        XCTAssertEqual(nas.upload.drive?.uploadUrl.host, "drive.example.edu")
        let bunny = try decode(ReviewUploadTicket.self, #"""
        {"data":{"media":{"id":"m9"},"version":{"id":"v9"},"upload":{"provider":"BUNNY","libraryId":"1","videoId":"x","signature":"s"}}}
        """#)
        XCTAssertNil(bunny.upload.drive, "the app only uploads to InFocus Drive")
        let project = try decode(ReviewCreatedProject.self, #"{"data":{"id":"p2","name":"New","workspaceId":"w1","description":null}}"#)
        XCTAssertEqual(project.id, "p2")
    }
}

final class ReviewDeepLinkTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func resolve(_ path: String) -> DeepLinkMatch {
        DeepLink.resolve(URL(string: "https://portal.example.edu\(path)")!, portal: portal)
    }

    func testWorkspacesOpenOnHome() {
        XCTAssertEqual(resolve("/workspaces"), DeepLinkMatch(tab: .home, route: .review(.workspaces)))
    }

    func testProjectLinks() {
        XCTAssertEqual(resolve("/projects/p1"), DeepLinkMatch(tab: .home, route: .review(.project(id: "p1"))))
        XCTAssertEqual(resolve("/projects/p1?folderId=f1&view=grid"),
                       DeepLinkMatch(tab: .home, route: .review(.project(id: "p1", folderId: "f1"))))
        XCTAssertEqual(resolve("/projects/p1?scope=active&folderId=all"),
                       DeepLinkMatch(tab: .home, route: .review(.project(id: "p1", folderId: nil))))
        XCTAssertEqual(resolve("/projects/p1?folderId=root"),
                       DeepLinkMatch(tab: .home, route: .review(.project(id: "p1", folderId: nil))))
    }

    func testReviewLinks() {
        XCTAssertEqual(resolve("/projects/p1/review/m1"),
                       DeepLinkMatch(tab: .home, route: .review(.media(projectId: "p1", mediaId: "m1"))))
        XCTAssertEqual(resolve("/projects/p1/review/m1?version=v2"),
                       DeepLinkMatch(tab: .home, route: .review(.media(projectId: "p1", mediaId: "m1", versionId: "v2"))))
    }

    func testOtherPathsStayWebPages() {
        XCTAssertNil(ReviewRoute.deepLink(["projects"], []))
        XCTAssertNil(ReviewRoute.deepLink(["projects", "p1", "review"], []))
        XCTAssertNil(ReviewRoute.deepLink(["projects", "p1", "settings", "x"], []))
        XCTAssertNil(ReviewRoute.deepLink(["workspaces", "w1"], []))
        XCTAssertTrue(resolve("/g/tok-abc").route?.isPortalPage == true, "guest links are for people without an account")
    }
}

final class ReviewLogicTests: XCTestCase {
    private func comment(_ id: String, _ target: ReviewComment.Target, time: Double = 0, parent: String? = nil,
                         version: String = "v1", minutesAgo: Double = 0) -> ReviewComment {
        ReviewComment(id: id, mediaVersionId: version, authorId: "u1", parentCommentId: parent, targetType: target, timeSeconds: time,
                      xPct: nil, yPct: nil, body: id, createdAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                      resolvedAt: nil, authorName: nil)
    }

    func testTimecodesAndFrames() {
        XCTAssertEqual(ReviewLogic.timecode(0), "00:00:00")
        XCTAssertEqual(ReviewLogic.timecode(65.9), "00:01:05")
        XCTAssertEqual(ReviewLogic.timecode(3_725), "01:02:05")
        XCTAssertEqual(ReviewLogic.timecode(-4), "00:00:00")
        XCTAssertEqual(ReviewLogic.timecode(.nan), "00:00:00")
        XCTAssertEqual(ReviewLogic.frameNumber(1.5), 45)
        XCTAssertEqual(ReviewLogic.frameNumber(.infinity), 0)
    }

    func testApprovalTransitionsMatchThePortal() {
        XCTAssertEqual(ReviewLogic.transitions(from: .inReview), [.needsChanges, .approved])
        XCTAssertEqual(ReviewLogic.transitions(from: .approved), [.needsChanges, .aired])
        XCTAssertEqual(ReviewLogic.transitions(from: .aired), [.needsChanges])
    }

    func testThreadsGroupRepliesAndOrderByTime() {
        let threads = ReviewLogic.threads([
            comment("general", .general, minutesAgo: 30),
            comment("late", .timecode, time: 40),
            comment("early", .timecode, time: 5),
            comment("reply2", .timecode, time: 5, parent: "early", minutesAgo: 1),
            comment("reply1", .timecode, time: 5, parent: "early", minutesAgo: 2),
            comment("other-version", .timecode, time: 1, version: "v2"),
        ], versionId: "v1")
        XCTAssertEqual(threads.map(\.id), ["early", "late", "general"])
        XCTAssertEqual(threads[0].replies.map(\.id), ["reply1", "reply2"])
    }

    func testPermissionsFollowTheWorkspaceRole() {
        XCTAssertTrue(ReviewLogic.canManageMedia(role: .reviewer, isProducer: true))
        XCTAssertTrue(ReviewLogic.canManageMedia(role: .editor, isProducer: false))
        XCTAssertFalse(ReviewLogic.canManageMedia(role: .reviewer, isProducer: false))
        XCTAssertFalse(ReviewLogic.canManageMedia(role: nil, isProducer: false))
        XCTAssertTrue(ReviewLogic.canResolve(role: .reviewer, own: true))
        XCTAssertFalse(ReviewLogic.canResolve(role: .reviewer, own: false))
        XCTAssertTrue(ReviewLogic.canResolve(role: .editor, own: false))
        XCTAssertTrue(ReviewLogic.canDelete(role: nil, own: true))
        XCTAssertFalse(ReviewLogic.canDelete(role: .reviewer, own: false))
        XCTAssertFalse(ReviewLogic.canRename(role: .reviewer))
        let shell = ReviewStub.shell(mediaId: nil)
        XCTAssertFalse(ReviewLogic.canShare(role: .ownerAdmin, shell: shell), "not a direct member")
    }

    func testTextLimitsAndURLs() {
        XCTAssertNil(ReviewLogic.cleanComment("   "))
        XCTAssertNil(ReviewLogic.cleanComment(String(repeating: "a", count: 2_001)))
        XCTAssertEqual(ReviewLogic.cleanComment("  Nice cut "), "Nice cut")
        XCTAssertEqual(ReviewLogic.cleanTitle(String(repeating: "b", count: 200))?.count, 150)
        XCTAssertEqual(MediaUploader.title(for: "Interview take 2.mov"), "Interview take 2")
        XCTAssertEqual(ReviewLogic.guestURL(token: "tok", portal: URL(string: "https://portal.example.edu")!).absoluteString,
                       "https://portal.example.edu/g/tok")
        XCTAssertEqual(ReviewLogic.reviewPath(projectId: "p1", mediaId: "m1", versionId: "v2"), "projects/p1/review/m1?version=v2")
        XCTAssertEqual(ReviewMediaQuery(folderId: nil).items.first { $0.name == "folderId" }?.value, "root",
                       "the top level only, in both scopes")
        XCTAssertEqual(ReviewMediaQuery(scope: .deleted, folderId: nil).items.first { $0.name == "folderId" }?.value, "root")
        XCTAssertEqual(ReviewMediaQuery(filter: .inProgress).items.first { $0.name == "filter" }?.value, "in-progress")
    }

    func testImageUploadIsAMultipartForm() throws {
        let body = ReviewImageUpload.body(projectId: "p1", folderId: "f1", title: "Booth", jpeg: Data([0xFF, 0xD8]), boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"projectId\"\r\n\r\np1"))
        XCTAssertTrue(text.contains("name=\"folderId\"\r\n\r\nf1"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"image.jpg\""))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
    }

    func testSampleProjectHasImagesAndComments() async throws {
        let api = ReviewAPI.stub
        let workspaces = try await api.workspaces()
        XCTAssertEqual(workspaces.first?.projects.first?.id, "p1")
        let page = try await api.media("p1", ReviewMediaQuery())
        XCTAssertTrue(page.items.contains { $0.currentVersion?.isImage == true })
        let quad = try await api.review("m-quad", nil)
        XCTAssertEqual(quad.title, "Quad at lunch")
        XCTAssertEqual(quad.folderName, "Photos")
        let booth = try await api.review("m-booth", nil)
        XCTAssertEqual(booth.comments.count, 3)
        XCTAssertEqual(booth.currentVersionId, "v-booth")
        XCTAssertTrue(booth.allowComment)
        let image = try await api.image("m-booth", "v-booth")
        XCTAssertFalse(image.isEmpty)
    }
}

/// The requests the live API sends, through `StubProtocol`.
final class ReviewAPIRequestTests: XCTestCase {
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

    private func body() throws -> [String: Any] {
        let data = try XCTUnwrap(StubProtocol.lastRequest?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPostsATimecodedComment() async throws {
        StubProtocol.handler = { _ in
            (201, Data(#"{"data":{"id":"c9","mediaVersionId":"v1","authorId":"u1","parentCommentId":null,"targetType":"TIMECODE","timeSeconds":7,"body":"Hi","createdAt":"2026-10-01T00:00:00.000Z","resolvedAt":null}}"#.utf8))
        }
        let created = try await api.comment(NewReviewComment(mediaVersionId: "v1", targetType: .timecode, timeSeconds: 7,
                                                             frameNumber: 210, body: "Hi"))
        XCTAssertEqual(created.id, "c9")
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/comments")
        let sent = try body()
        XCTAssertEqual(sent["targetType"] as? String, "TIMECODE")
        XCTAssertEqual(sent["timeSeconds"] as? Double, 7)
        XCTAssertEqual(sent["frameNumber"] as? Int, 210)
        XCTAssertNil(sent["xPct"], "unset fields are left out")
    }

    func testResolvesAndDeletes() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"id":"c1"}}"#.utf8)) }
        try await api.setResolved("c1", true)
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/comments/c1")
        XCTAssertEqual(try body()["resolved"] as? Bool, true)
        try await api.deleteComment("c1")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "DELETE")
    }

    func testApprovalSendsAiredDateOnlyWhenAired() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"id":"v1"}}"#.utf8)) }
        try await api.setApproval("m1", "v1", .approved, Date())
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/media/m1/approval-status")
        XCTAssertNil(try body()["airedAt"])
        try await api.setApproval("m1", "v1", .aired, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try body()["airedAt"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(try body()["status"] as? String, "AIRED")
    }

    func testMediaPageQuery() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"items":[],"totalCount":0,"page":2,"pageSize":40,"totalPages":2}}"#.utf8)) }
        _ = try await api.media("p1", ReviewMediaQuery(scope: .deleted, folderId: "f1", filter: .ready, sort: .name, page: 2))
        let url = try XCTUnwrap(StubProtocol.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/projects/p1/media")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "scope" }?.value, "deleted")
        XCTAssertEqual(query.first { $0.name == "folderId" }?.value, "f1")
        XCTAssertEqual(query.first { $0.name == "sort" }?.value, "name")
        XCTAssertEqual(query.first { $0.name == "page" }?.value, "2")
    }

    func testForbiddenIsReported() async {
        StubProtocol.handler = { _ in (403, Data(#"{"error":{"message":"Forbidden"}}"#.utf8)) }
        do {
            _ = try await api.guestLinks("p1")
            XCTFail("expected forbidden")
        } catch {
            XCTAssertEqual(error as? PortalError, .forbidden("Forbidden"))
        }
    }
}
