import XCTest
@testable import InFocusPortal

/// The student's native stage pages: decoding, the Portal's status words, deep links
/// and the calls they make (fixtures use placeholder people only).
final class StudentStagesTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
    }

    private func row(stage: String = "DRAFT", needsRevisions: Bool = false, awaiting: Bool = false, aRoll: Bool = false,
                     aRollChanges: Bool = false, finalCut: Bool = false, queued: Bool = false, remaining: Int? = 2) -> StageRow {
        StageRow(id: "r1", cycleNumber: 2, groupTopic: "Club Fair", headline: nil, toss: nil, proofOfContact: true,
                 aRollBRoll: aRoll, aRollNeedsChanges: aRollChanges, initialCut: false, finalCut: finalCut,
                 awaitingRevisedInitialCut: awaiting, initialCutNeedsRevisions: needsRevisions,
                 queuedForAirAt: queued ? Date() : nil, approvalStage: stage, remainingExecutiveSignoffs: remaining,
                 assignedProducer: nil, members: [])
    }

    private func view(_ slug: String, row: StageRow, media: Int = 1, unlocked: Bool = true) -> StageView {
        StageView(empty: false, slug: slug, isProducer: false, unlocked: unlocked, canUpload: true, canComment: false,
                  canApproveAroll: false, allowSecondFinalCut: false, cutApproval: nil, row: row,
                  media: (0..<media).map { WorkStub.clip("m\($0)", "Clip", nil) })
    }

    // MARK: Decoding

    func testDecodesFinalCutStageForStudent() throws {
        let view = try decode(StageView.self, """
        {"data":{"empty":false,"slug":"final-cut","isProducer":false,"unlocked":true,"canUpload":false,"allowSecondFinalCut":true,
          "canComment":false,"cutApproval":null,"canApproveAroll":false,"canGradeFinalCut":false,"finalCutGrade":null,
          "packageOfCycle":null,"canEditToss":true,
          "row":{"id":"r1","cycleNumber":3,"groupTopic":"Robotics","headline":"Robots take the stage","toss":"Next up, robots.",
            "packageOfCycleAt":"2026-10-12T17:00:00.000Z","proofOfContact":true,"aRollBRoll":true,"aRollNeedsChanges":false,
            "initialCut":true,"finalCut":true,"awaitingRevisedInitialCut":false,"initialCutNeedsRevisions":false,
            "queuedForAirAt":null,"approvalStage":"APPROVED","remainingExecutiveSignoffs":0,
            "assignedProducer":{"id":"u-sage","name":"Sage","email":"sage@example.edu"},
            "members":[{"userId":"u-abby","name":"Abby","email":"abby@example.edu"},{"userId":"u-otto","name":null,"email":"otto@example.edu"}]},
          "media":[{"id":"f1","title":"Robots take the stage","rollKind":null,"projectId":"p1","versionId":"v1","versionNumber":1,
            "status":"PROCESSING","thumbnailUrl":null,"playbackUrl":null,"commentCount":0}]}}
        """)
        XCTAssertEqual(view.canEditToss, true)
        XCTAssertEqual(view.allowSecondFinalCut, true)
        XCTAssertNotNil(view.row?.packageOfCycleAt)
        XCTAssertEqual(view.row?.toss, "Next up, robots.")
        XCTAssertEqual(view.row?.assignedProducer?.displayName, "Sage")
        XCTAssertEqual(view.row?.memberNames, "Abby, otto")
        XCTAssertEqual(StageGuide.status(.finalCut, view: view), .submitted)
        XCTAssertEqual(StageGuide.mediaStatusLabel(view.media?.first?.status ?? ""), "Processing")
    }

    func testDecodesGatesWithExecutiveCount() throws {
        let gates = try decode(StudentGates.self, """
        {"data":{"cycleNumber":2,"hasRow":true,"unlocked":{"a-roll":true,"initial-cut":true,"final-cut":false},
          "statuses":{"brainstorming":"approved","a-roll":"approved","initial-cut":"stage-3","final-cut":"locked"},
          "remainingExecutiveSignoffs":1,"unread":{"brainstorming":0,"a-roll":0,"initial-cut":1,"final-cut":0}}}
        """)
        XCTAssertEqual(gates.remainingExecutiveSignoffs, 1)
        let status = try XCTUnwrap(gates.status(.initialCut))
        XCTAssertEqual(StageGuide.label(status, remainingExecutiveSignoffs: gates.remainingExecutiveSignoffs), "1 exec left")
    }

    func testDecodesCommentsWithReviewLinksAndClipNotes() throws {
        let comments = try decode(StageComments.self, """
        {"data":{"comments":[
          {"id":"c3","rowId":"r1","stage":"a-roll","body":"[[clip:m2]]\\nThe wide shot is soft.","createdAt":"2026-10-03T18:00:00.000Z",
           "resolvedAt":null,"reviewHref":null,"author":{"userId":"u-sage","name":"Sage","email":"sage@example.edu"}},
          {"id":"c2","rowId":"r1","stage":"initial-cut","body":"Left notes in the review.","createdAt":"2026-10-02T18:00:00.000Z",
           "resolvedAt":"2026-10-02T19:00:00.000Z","reviewHref":"/projects/p1/review/m1?v=v2",
           "author":{"userId":"u-sage","name":"Sage","email":"sage@example.edu"}},
          {"id":"c1","rowId":"r1","stage":"a-roll","body":"Reshoot the interview.","createdAt":"2026-10-01T18:00:00.000Z",
           "author":{"userId":"u-sage","name":"Sage","email":"sage@example.edu"}}],"unread":0}}
        """)
        XCTAssertNotNil(comments.comments[1].resolvedAt)
        XCTAssertEqual(comments.comments[1].reviewHref, "/projects/p1/review/m1?v=v2")

        let group = StageThread(comments.comments, clipId: nil)
        XCTAssertEqual(group.comments.map(\.id), ["c2", "c1"])
        XCTAssertEqual(group.onClips, 1)
        let clip = StageThread(comments.comments, clipId: "m2")
        XCTAssertEqual(clip.comments.map(\.body), ["The wide shot is soft."])
        XCTAssertEqual(clip.onClips, 0)
    }

    func testDecodesBrainstormWithCyclesAndRevisions() throws {
        let payload = try decode(BrainstormPayload.self, """
        {"data":{"currentUserId":"u-abby","canApprove":false,"activeCycleNumber":2,
          "cycles":[{"cycleNumber":1,"focus":"News"},{"cycleNumber":2,"focus":""}],
          "packages":[{"id":"r1","cycleNumber":2,"groupTopic":"Club Fair","brainstormDocUrl":"https://docs.google.com/document/d/x",
            "proofOfContact":false,"needsChanges":true,"canEdit":true,"assignedProducer":{"userId":"u-sage","name":"Sage","email":"sage@example.edu"},
            "members":[{"userId":"u-abby","name":"Abby","email":"abby@example.edu"}],
            "proofs":[{"id":"p1","slot":1,"fileName":"a.jpg","mimeType":"image/jpeg","imageUrl":"/api/brainstorming/proofs/p1/image"},
                      {"id":"p2","slot":2,"fileName":"b.jpg","mimeType":"image/jpeg","imageUrl":"/api/brainstorming/proofs/p2/image"},
                      {"id":"p3","slot":3,"fileName":"c.jpg","mimeType":"image/jpeg","imageUrl":"/api/brainstorming/proofs/p3/image"}]}]}}
        """)
        XCTAssertEqual(payload.cycles?.map(\.cycleNumber), [1, 2])
        let package = try XCTUnwrap(payload.packages.first)
        XCTAssertEqual(package.canEdit, true)
        XCTAssertEqual(BrainstormGuide.status(package), .needsRevisions)
        XCTAssertTrue(BrainstormGuide.nextStep(package).hasPrefix("Your producer asked for changes."))
        XCTAssertEqual(BrainstormGuide.metaLine(members: package.members, producer: package.assignedProducer), "Abby · Producer: Sage")
    }

    func testDecodesResolvedComment() throws {
        let answer = try decode(ResolvedComment.self, #"{"data":{"comment":{"id":"c1","resolvedAt":"2026-10-02T19:00:00.000Z"}}}"#)
        XCTAssertNotNil(answer.comment.resolvedAt)
        let reopened = try decode(ResolvedComment.self, #"{"data":{"comment":{"id":"c1","resolvedAt":null}}}"#)
        XCTAssertNil(reopened.comment.resolvedAt)
    }

    // MARK: Status words (match src/lib/package-stage-status.ts)

    func testStageStatusesFollowThePortal() {
        XCTAssertEqual(StageGuide.status(.aRoll, view: view("a-roll", row: row(), media: 0)), .pending)
        XCTAssertEqual(StageGuide.status(.aRoll, view: view("a-roll", row: row())), .submitted)
        XCTAssertEqual(StageGuide.status(.aRoll, view: view("a-roll", row: row(aRollChanges: true))), .needsRevisions)
        XCTAssertEqual(StageGuide.status(.aRoll, view: view("a-roll", row: row(aRoll: true))), .approved)
        XCTAssertEqual(StageGuide.status(.aRoll, view: view("a-roll", row: row(), unlocked: false)), .locked)

        XCTAssertEqual(StageGuide.status(.initialCut, view: view("initial-cut", row: row(), media: 0)), .pending)
        XCTAssertEqual(StageGuide.status(.initialCut, view: view("initial-cut", row: row(stage: "DRAFT"))), .needsRevisions)
        XCTAssertEqual(StageGuide.status(.initialCut, view: view("initial-cut", row: row(stage: "ASSOCIATE_REVIEW"))), .submitted)
        XCTAssertEqual(StageGuide.status(.initialCut, view: view("initial-cut", row: row(stage: "ASSOCIATE_REVIEW", awaiting: true))),
                       .stage1Approved)
        XCTAssertEqual(StageGuide.status(.initialCut, view: view("initial-cut", row: row(stage: "ADVISER_REVIEW"))), .stage2)
        XCTAssertEqual(StageGuide.status(.initialCut, view: view("initial-cut", row: row(stage: "EXECUTIVE_REVIEW"))), .stage3)
        XCTAssertEqual(StageGuide.status(.initialCut, view: view("initial-cut", row: row(stage: "EXECUTIVE_REVIEW", needsRevisions: true))),
                       .needsRevisions)
        XCTAssertEqual(StageGuide.status(.initialCut, view: view("initial-cut", row: row(stage: "APPROVED"))), .approved)

        XCTAssertEqual(StageGuide.status(.finalCut, view: view("final-cut", row: row(stage: "APPROVED"), media: 0)), .pending)
        XCTAssertEqual(StageGuide.status(.finalCut, view: view("final-cut", row: row(stage: "APPROVED", queued: true))), .approved)
    }

    func testNextStepsAndRules() {
        XCTAssertEqual(StageGuide.nextStep(.initialCut, status: .locked, hasFinalCut: false), "Unlocks when A-roll/B-roll is approved.")
        XCTAssertEqual(StageGuide.nextStep(.initialCut, status: .approved, hasFinalCut: false),
                       "Approved for Final Cut. Next, upload your Final Cut with a headline and a toss for the anchors.")
        XCTAssertEqual(StageGuide.nextStep(.finalCut, status: .submitted, hasFinalCut: true),
                       "Turned in. Your executive producers grade it next.")
        XCTAssertEqual(StageGuide.uploadLabel(.initialCut, hasMedia: true, allowSecondFinalCut: false), "Upload new version")
        XCTAssertEqual(StageGuide.uploadLabel(.finalCut, hasMedia: true, allowSecondFinalCut: true), "Upload revised Final Cut")
        XCTAssertNil(StageGuide.uploadRule(.initialCut, hasMedia: false))
        XCTAssertTrue(StageGuide.finalCutRule(allowSecondFinalCut: false).contains("only upload Final Cut once"))
    }

    func testApprovalPath() {
        let none = StageGuide.approvalPath(row(stage: "ASSOCIATE_REVIEW"), hasMedia: false)
        XCTAssertEqual(none.map(\.state), [.upcoming, .upcoming, .upcoming])

        let stage3 = StageGuide.approvalPath(row(stage: "EXECUTIVE_REVIEW", remaining: 2), hasMedia: true)
        XCTAssertEqual(stage3.map(\.state), [.done, .done, .current])
        XCTAssertEqual(stage3.last?.stateLabel, "2 execs left")

        let sentBack = StageGuide.approvalPath(row(stage: "ADVISER_REVIEW", needsRevisions: true), hasMedia: true)
        XCTAssertEqual(sentBack[1].stateLabel, "Needs revisions")
        XCTAssertEqual(sentBack[1].tone, .danger)

        let awaiting = StageGuide.approvalPath(row(stage: "ASSOCIATE_REVIEW", awaiting: true), hasMedia: true)
        XCTAssertEqual(awaiting[0].stateLabel, "Approved · awaiting revised upload")

        let approved = StageGuide.approvalPath(row(stage: "APPROVED"), hasMedia: true)
        XCTAssertEqual(approved.map(\.state), [.done, .done, .done])
    }

    func testCutResultsAndReviewLinks() {
        var media = WorkStub.clip("m1", "Initial Cut Version 1", nil)
        XCTAssertEqual(StageGuide.cutResult(media).label, "Pending review")
        media = StageMedia(id: "m1", title: "v2", rollKind: nil, projectId: "p1", versionId: "v2", versionNumber: 2, status: "READY",
                           approvalStatus: "NEEDS_CHANGES", approvedInStage: nil, thumbnailUrl: nil, playbackUrl: nil, commentCount: 0, isNew: nil)
        XCTAssertEqual(StageGuide.cutResult(media).label, "Needs revisions")
        XCTAssertEqual(media.reviewRoute, .media(projectId: "p1", mediaId: "m1", versionId: "v2"))
        XCTAssertEqual(StageGuide.cutTitle(version: 3), "Initial Cut Version 3")
    }

    func testBrainstormNextSteps() {
        func package(proofs: Int, doc: String, approved: Bool = false) -> BrainstormPackage {
            BrainstormPackage(id: "r1", cycleNumber: 2, groupTopic: "Club Fair", brainstormDocUrl: doc, proofOfContact: approved,
                              assignedProducer: nil, members: [],
                              proofs: (0..<proofs).map { ProofView(id: "p\($0)", slot: $0 + 1, fileName: "p.jpg", imageUrl: "/x") })
        }
        XCTAssertEqual(BrainstormGuide.nextStep(package(proofs: 0, doc: "")), "Add 3 proofs and the Google Doc link.")
        XCTAssertEqual(BrainstormGuide.nextStep(package(proofs: 2, doc: "https://docs.google.com/d/x")), "Add 1 more proof.")
        XCTAssertEqual(BrainstormGuide.nextStep(package(proofs: 3, doc: "")), "Add the Google Doc link.")
        XCTAssertEqual(BrainstormGuide.nextStep(package(proofs: 3, doc: "https://docs.google.com/d/x")),
                       "Everything is in. Waiting for your producer to review.")
        XCTAssertEqual(BrainstormGuide.status(package(proofs: 0, doc: "", approved: true)), .approved)
    }

    func testClipCommentParsing() {
        XCTAssertEqual(ClipComment.parse("[[clip:m9]]\nToo dark").clipId, "m9")
        XCTAssertEqual(ClipComment.parse("[[clip:m9]]\nToo dark").text, "Too dark")
        XCTAssertNil(ClipComment.parse("Plain note").clipId)
        XCTAssertNil(ClipComment.parse("[[clip:]]\nx").clipId)
    }

    func testCycleGuideCopy() {
        XCTAssertEqual(CycleGuideScreen.stages.map(\.marker), [nil, "1", "2", "3.1", "3.2", "3.3", "4"])
        XCTAssertEqual(CycleGuideScreen.approval.count, 3)
    }

    // MARK: Deep links

    func testStudentStageDeepLinks() {
        for stage in StudentStage.allCases {
            XCTAssertEqual(WorkRoute.deepLink([stage.rawValue], []), DeepLinkMatch(tab: .work, route: .work(.studentStage(stage))))
        }
        XCTAssertEqual(WorkRoute.deepLink(["brainstorming"], [URLQueryItem(name: "cycle", value: "2")])?.route,
                       .work(.studentStage(.brainstorming)))
        XCTAssertNil(WorkRoute.deepLink(["a-roll", "extra"], []))
        XCTAssertNil(WorkRoute.deepLink(["initial-stage-2"], []))
    }

    // MARK: Uploads

    @MainActor
    func testBatchSkipsTooBigClipsBeforeUploading() async {
        let uploader = StageUploader()
        let file = StageUploadFile(url: URL(fileURLWithPath: "/nonexistent/clip.mov"), name: "clip.mov",
                                   problem: PackageText.rollSizeError(kind: "b-roll", bytes: 16 * 1_073_741_824))
        let uploaded = await uploader.uploadBatch([file], api: .stub) { _, _ in
            StageUploadRequest(rowId: "r1", stage: .aRoll, title: "clip", fileName: "clip.mov")
        }
        XCTAssertEqual(uploaded, 0)
        XCTAssertEqual(uploader.phase, .failed("clip.mov: B-roll files must be 15 GB or smaller."))
    }
}

/// The student stage writes go to the website's routes.
final class StudentStageRequestTests: XCTestCase {
    private func api() -> WorkAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return .live(PortalClient(portal: URL(string: "https://portal.example.edu")!, session: URLSession(configuration: config),
                                  cookies: { [] }))
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    private func body() throws -> [String: Any] {
        let data = try XCTUnwrap(StubProtocol.lastRequest?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func query() -> [String: String] {
        let items = URLComponents(url: StubProtocol.lastRequest!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testSaveToss() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"ok":true}}"#.utf8)) }
        try await api().saveToss("r1", "Next up, the Club Fair.")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/package-cycle/toss")
        let sent = try body()
        XCTAssertEqual(sent["rowId"] as? String, "r1")
        XCTAssertEqual(sent["toss"] as? String, "Next up, the Club Fair.")
    }

    func testRemoveProof() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"ok":true}}"#.utf8)) }
        try await api().removeProof("r1", 2)
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/brainstorming/proofs")
        XCTAssertEqual(query(), ["rowId": "r1", "slot": "2"])
    }

    func testResolveComment() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"comment":{"id":"c1","resolvedAt":"2026-10-02T19:00:00.000Z"}}}"#.utf8)) }
        let resolvedAt = try await api().resolveComment("c1", true)
        XCTAssertNotNil(resolvedAt)
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/package-cycle/comments")
        let sent = try body()
        XCTAssertEqual(sent["id"] as? String, "c1")
        XCTAssertEqual(sent["resolved"] as? Bool, true)
    }

    func testCertificateAndClearingTheDocLink() async throws {
        StubProtocol.handler = { _ in (200, Data([0x89, 0x50, 0x4E, 0x47])) }
        let png = try await api().certificate("r1")
        XCTAssertEqual(png.count, 4)
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/package-cycle/package-of-cycle/certificate")
        XCTAssertEqual(query(), ["rowId": "r1"])

        StubProtocol.handler = { _ in (200, Data(#"{"data":{"package":{}}}"#.utf8)) }
        try await api().saveDocLink("r1", "")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PATCH")
        let sent = try body()
        XCTAssertEqual(sent["kind"] as? String, "doc")
        XCTAssertEqual(sent["url"] as? String, "")
    }

    func testFinalCutUploadSendsHeadlineAndToss() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"data":{"mediaId":"m1","versionId":"v1","upload":{"provider":"NAS","uploadUrl":"https://drive.example.edu/api/upload","path":"x.mov","token":"t"}}}"#.utf8))
        }
        let request = StageUploadRequest(rowId: "r1", stage: .finalCut, title: "Robots take the stage", fileName: "final.mov",
                                         toss: "Next up, robots.")
        let ticket = try await api().startUpload(request)
        XCTAssertEqual(ticket.mediaId, "m1")
        let sent = try body()
        XCTAssertEqual(sent["action"] as? String, "init")
        XCTAssertEqual(sent["stage"] as? String, "final-cut")
        XCTAssertEqual(sent["title"] as? String, "Robots take the stage")
        XCTAssertEqual(sent["toss"] as? String, "Next up, robots.")
    }
}
