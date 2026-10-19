import XCTest
@testable import InFocusPortal

/// Groups review: decoding the producer stage payloads, the website's grading and approval
/// rules, the request bodies, and the `/groups/…` deep links. Placeholder people only.
final class GroupReviewTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
    }

    private func client() -> PortalClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return PortalClient(portal: portal, session: URLSession(configuration: config), cookies: { [] }, onUnauthorized: {})
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    static let finalCutJSON = """
    {"data":{"empty":false,"slug":"final-cut","isProducer":true,"unlocked":true,"canUpload":false,"allowSecondFinalCut":false,
      "canComment":true,"cutApproval":null,"canApproveAroll":false,"canGradeFinalCut":true,"canEditToss":true,
      "finalCutGrade":{"canGrade":true,"complete":false,"viewerUserId":"u-kai","deadlineAt":"2026-10-07T06:59:00.000Z",
        "turnedInAt":"2026-10-09T18:00:00.000Z","extensionDays":1.5,"daysLate":2,"penaltyMultiplier":0.2,
        "blocksSecondRevision":false,"secondRevisionEligible":false,"feedback":"Strong open.","published":false,"publishedAt":null,
        "members":[{"userId":"u-abby","name":"Abby","email":"abby@example.edu","myQuality":20,"myEffort":22.5,"locked":false,
          "complete":false,"pendingCount":1,"qualityAverage":null,"effortAverage":null,"average":null,"afterRevisionCap":null,
          "revisionCapped":false,"officialPoints":null,"revisionCount":0,"secondRevisionEligible":false,"daysLate":2,
          "penaltyMultiplier":0.15,"automaticPenaltyMultiplier":0.2,"latePenaltyPercent":15,
          "graderScores":[{"userId":"u-kai","name":"Kai Example","required":true,"quality":20,"effort":22.5},
                          {"userId":"u-sage","name":"Sage Example","required":true,"quality":null,"effort":null}]}],
        "graders":[{"userId":"u-kai","name":"Kai Example","email":"kai@example.edu","required":true,"scoredCount":1},
                   {"userId":"u-sage","name":null,"email":"sage@example.edu","required":true,"scoredCount":0}]},
      "packageOfCycle":{"canVote":true,"myVote":false,"awardedAt":null,"blockedReason":"Two packages already won this cycle.",
        "graders":[{"userId":"u-kai","name":"Kai Example","voted":false}]},
      "row":{"id":"r1","cycleNumber":2,"groupTopic":"Club Fair","headline":"Club Fair returns","toss":"","packageOfCycleAt":null,
        "finalCut":true,"proofOfContact":true,"aRollBRoll":true,"aRollNeedsChanges":false,"initialCut":true,
        "awaitingRevisedInitialCut":false,"initialCutNeedsRevisions":false,"queuedForAirAt":null,"approvalStage":"APPROVED",
        "remainingExecutiveSignoffs":0,"assignedProducer":null,
        "members":[{"userId":"u-abby","name":"Abby","email":"abby@example.edu"}]},
      "media":[{"id":"f1","title":"Club Fair returns","rollKind":null,"projectId":"p1","versionId":"v1","versionNumber":1,
        "status":"READY","thumbnailUrl":null,"playbackUrl":null,"commentCount":0}]}}
    """

    // MARK: Decoding

    func testDecodesFinalCutGradeAndPackageOfCycle() throws {
        let extras = try decode(GroupStageExtras.self, Self.finalCutJSON)
        let grade = try XCTUnwrap(extras.finalCutGrade)
        XCTAssertTrue(grade.canGrade)
        XCTAssertEqual(grade.extensionDays, 1.5)
        XCTAssertEqual(grade.feedback, "Strong open.")
        XCTAssertEqual(grade.members.first?.latePenaltyPercent, 15)
        XCTAssertEqual(grade.members.first?.myEffort, 22.5)
        XCTAssertEqual(grade.members.first?.graderScores.count, 2)
        XCTAssertEqual(grade.graders[1].label, "sage@example.edu")
        XCTAssertEqual(grade.scoringMembers, 1)
        XCTAssertEqual(extras.canEditToss, true)
        let panel = try XCTUnwrap(extras.packageOfCycle)
        XCTAssertTrue(panel.voteBlocked)
        XCTAssertEqual(panel.votes, 0)
        // The same payload still decodes as the shared stage view.
        let view = try decode(StageView.self, Self.finalCutJSON)
        XCTAssertEqual(view.row?.headline, "Club Fair returns")
    }

    func testDecodesStageWithoutExtras() throws {
        let extras = try decode(GroupStageExtras.self, #"{"data":{"empty":true,"slug":"a-roll","isProducer":true}}"#)
        XCTAssertNil(extras.finalCutGrade)
        XCTAssertNil(extras.packageOfCycle)
    }

    func testDecodesNotesWithResolvedReviewAndClip() throws {
        let notes = try decode(GroupNotes.self, """
        {"data":{"comments":[
          {"id":"c1","rowId":"r1","stage":"initial-cut","body":"Sage submitted a review. Open Review to see comments.",
           "createdAt":"2026-10-02T19:32:36.224Z","resolvedAt":"2026-10-03T10:00:00.000Z",
           "reviewHref":"/projects/p1/review/m1?bare=1&version=v2","author":{"userId":"u-sage","name":"Sage","email":"sage@example.edu"}},
          {"id":"c2","rowId":"r1","stage":"a-roll","body":"[[clip:m7]]\\nAudio dips here.","createdAt":"2026-10-02T19:32:36Z",
           "resolvedAt":null,"reviewHref":null,"author":{"userId":"u-kai","name":null,"email":"kai@example.edu"}}],"unread":0}}
        """)
        XCTAssertEqual(notes.comments.count, 2)
        XCTAssertNotNil(notes.comments[0].resolvedAt)
        XCTAssertEqual(notes.comments[0].reviewHref, "/projects/p1/review/m1?bare=1&version=v2")
        XCTAssertNil(notes.comments[0].clipId)
        XCTAssertEqual(notes.comments[1].clipId, "m7")
        XCTAssertEqual(notes.comments[1].text, "Audio dips here.")
        XCTAssertEqual(notes.comments[1].authorName, "kai@example.edu")
    }

    func testClipMarkerRoundTrip() {
        let wrapped = GroupNote.wrapClip("m1", "Hold the wide shot.")
        XCTAssertEqual(wrapped, "[[clip:m1]]\nHold the wide shot.")
        XCTAssertEqual(GroupNote.parseClip(wrapped).clipId, "m1")
        XCTAssertNil(GroupNote.parseClip("[[approved]]\nNice").clipId)
        XCTAssertNil(GroupNote.parseClip("Plain note").clipId)
    }

    func testDecodesScoreResultNotesAndVote() throws {
        let result = try decode(FinalCutScoreResult.self, #"{"data":{"savedCount":2,"gradedCount":1,"complete":false}}"#)
        XCTAssertEqual(GroupReviewLogic.savedMessage(result), "Saved. 1 member now have an official grade.")
        XCTAssertEqual(GroupReviewLogic.savedMessage(.init(savedCount: 0, gradedCount: 0, complete: false)),
                       "Nothing saved. Those members keep their earlier grade.")
        let notes = try decode(GroupRosterNotes.self, #"{"data":{"possibleIdeas":"Ask the club president."}}"#)
        XCTAssertEqual(notes.possibleIdeas, "Ask the club president.")
        let panel = try decode(PackageOfCyclePanel.self, """
        {"data":{"canVote":true,"myVote":true,"awardedAt":"2026-10-10T00:00:00.000Z","blockedReason":null,
          "graders":[{"userId":"u-kai","name":"Kai","voted":true},{"userId":"u-sage","name":"Sage","voted":true}]}}
        """)
        XCTAssertEqual(panel.votes, 2)
        XCTAssertNotNil(panel.awardedAt)
        XCTAssertFalse(panel.voteBlocked)
    }

    // MARK: Grading rules

    private var grade: FinalCutGrade { GroupReviewFixtures.finalCutGrade }

    func testScoresFromDraft() {
        let members = grade.members
        var draft = GroupReviewLogic.draft(from: members)
        XCTAssertFalse(GroupReviewLogic.isDirty(members, draft))
        XCTAssertEqual(GroupReviewLogic.scores(members, draft), .failure(.init(message: "Enter at least one member's scores.")))

        draft["u-abby"] = .init(quality: "20", effort: "")
        XCTAssertTrue(GroupReviewLogic.isDirty(members, draft))
        XCTAssertEqual(GroupReviewLogic.scores(members, draft), .failure(.init(message: "Enter both quality and effort for Abby.")))

        draft["u-abby"] = .init(quality: "26", effort: "10")
        XCTAssertEqual(GroupReviewLogic.scores(members, draft), .failure(.init(message: "Scores for Abby must be between 0 and 25.")))

        draft["u-abby"] = .init(quality: "20", effort: "22.5")
        guard case .success(let scores) = GroupReviewLogic.scores(members, draft) else { return XCTFail("expected scores") }
        XCTAssertEqual(scores, [FinalCutScoreInput(memberUserId: "u-abby", qualityPoints: 20, effortPoints: 22.5)])
    }

    func testLateStatusAndPenaltyLabels() {
        let status = GroupReviewLogic.lateStatus(grade)
        XCTAssertEqual(status.label, "Late · 20% off")
        XCTAssertEqual(status.tone, .warning)
        let member = grade.members[0]
        XCTAssertEqual(GroupReviewLogic.penaltyLabel(member), "Auto −20%")
        XCTAssertEqual(GroupReviewLogic.automaticPenaltyLabel(member), "−20% · 2 days late")
        XCTAssertEqual(GroupReviewLogic.effectivePenalty(member), "−20%")
        XCTAssertEqual(GroupReviewLogic.summary(member), "Waiting on Kai")
        XCTAssertEqual(GroupReviewLogic.deductionDetail(grade), "Taken off the official grade")
    }

    func testExecutiveOverridePenalty() throws {
        let extras = try decode(GroupStageExtras.self, Self.finalCutJSON)
        let member = try XCTUnwrap(extras.finalCutGrade?.members.first)
        XCTAssertEqual(GroupReviewLogic.penaltyLabel(member), "−15%")
        XCTAssertEqual(GroupReviewLogic.effectivePenalty(member), "−15% · set by an executive producer")
    }

    func testTossRules() {
        XCTAssertEqual(GroupReviewLogic.tossError("  "), "Add a toss for the anchors.")
        XCTAssertEqual(GroupReviewLogic.tossError("Hold for {CUE}"), "The toss can't include < > [ ] { }.")
        XCTAssertNotNil(GroupReviewLogic.tossError(String(repeating: "a", count: 501)))
        XCTAssertNil(GroupReviewLogic.tossError("Abby and Otto went to the fair."))
    }

    // MARK: Approval rules

    func testWhoMayAct() {
        let adviser = PortalUser(email: "adviser@example.edu", name: "Ada", role: .adviser, onStudentPackage: false)
        let associate = PortalUser(email: "otto@example.edu", name: "Otto", role: .associateProducer, onStudentPackage: true)
        let student = PortalUser(email: "abby@example.edu", name: "Abby", role: nil, onStudentPackage: true)
        XCTAssertTrue(GroupReviewLogic.mayAct(adviser, assignedProducerEmail: nil, memberEmails: []))
        XCTAssertTrue(GroupReviewLogic.mayAct(associate, assignedProducerEmail: "Otto@example.edu", memberEmails: ["abby@example.edu"]))
        XCTAssertFalse(GroupReviewLogic.mayAct(associate, assignedProducerEmail: "sage@example.edu", memberEmails: []))
        XCTAssertFalse(GroupReviewLogic.mayAct(associate, assignedProducerEmail: "otto@example.edu", memberEmails: ["otto@example.edu"]))
        XCTAssertFalse(GroupReviewLogic.mayAct(student, assignedProducerEmail: "abby@example.edu", memberEmails: []))
        // Stage 3 grading: the adviser is never an executive producer.
        XCTAssertFalse(adviser.isExecutive)
    }

    func testReviewStagesAndApprovalPath() {
        XCTAssertEqual(GroupReviewLogic.reviewStage(for: "ASSOCIATE_REVIEW"), 1)
        XCTAssertEqual(GroupReviewLogic.reviewStage(for: "ADVISER_REVIEW"), 2)
        XCTAssertEqual(GroupReviewLogic.reviewStage(for: "APPROVED"), 3)
        XCTAssertNil(GroupReviewLogic.reviewStage(for: "DRAFT"))

        let path = GroupReviewLogic.approvalPath(approvalStage: "EXECUTIVE_REVIEW", hasMedia: true, needsRevisions: false,
                                                 awaitingRevisedInitialCut: false, remainingExecutiveSignoffs: 1)
        XCTAssertEqual(path.map(\.state), [.done, .done, .current])
        XCTAssertEqual(path[2].stateLabel, "1 exec left")

        let sentBack = GroupReviewLogic.approvalPath(approvalStage: "DRAFT", hasMedia: true, needsRevisions: true,
                                                     awaitingRevisedInitialCut: false, remainingExecutiveSignoffs: nil)
        XCTAssertEqual(sentBack[0].stateLabel, "Needs revisions")
        XCTAssertEqual(sentBack[0].tone, .danger)

        let empty = GroupReviewLogic.approvalPath(approvalStage: "ASSOCIATE_REVIEW", hasMedia: false, needsRevisions: false,
                                                  awaitingRevisedInitialCut: false, remainingExecutiveSignoffs: nil)
        XCTAssertEqual(empty.map(\.state), [.upcoming, .upcoming, .upcoming])
    }

    func testReviewRouteOpensTheNativeReview() {
        let clip = WorkStub.clip("m3", "Initial Cut Version 1", nil)
        XCTAssertEqual(clip.reviewRoute, .media(projectId: "p1", mediaId: "m3", versionId: "v-m3"))
    }

    // MARK: Request bodies

    func testCutActionBodies() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json(_ action: CutAction) throws -> String { String(data: try encoder.encode(CutActionBody(action)), encoding: .utf8)! }
        XCTAssertEqual(try json(.approve(note: "  Nice pacing ", versionId: "v2")),
                       #"{"action":"DECIDE","approved":true,"mediaVersionId":"v2","note":"Nice pacing"}"#)
        XCTAssertEqual(try json(.approve(note: "", versionId: nil)), #"{"action":"DECIDE","approved":true}"#)
        XCTAssertEqual(try json(.needsRevisions(versionId: "v2")), #"{"action":"SUBMIT_REVIEW","mediaVersionId":"v2"}"#)
        XCTAssertEqual(try json(.unapprove), #"{"action":"UNAPPROVE"}"#)
        XCTAssertEqual(try json(.approveAnyway), #"{"action":"APPROVE_ANYWAY"}"#)
    }

    func testPenaltyBodySendsNullForAutomatic() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let automatic = String(data: try encoder.encode(PenaltyBody(rowId: "r1", memberUserId: "u-abby", percent: nil)), encoding: .utf8)
        XCTAssertEqual(automatic, #"{"memberUserId":"u-abby","percent":null,"rowId":"r1"}"#)
    }

    func testStageRequestDecodesViewAndExtrasFromOneCall() async throws {
        StubProtocol.handler = { _ in (200, Data(Self.finalCutJSON.utf8)) }
        let bundle = try await GroupReviewService(client: client()).stage("final-cut", rowId: "r1", reviewStage: nil)
        let url = try XCTUnwrap(StubProtocol.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/package-cycle/stage")
        XCTAssertEqual(url.query, "stage=final-cut&rowId=r1")
        XCTAssertEqual(bundle.view.slug, "final-cut")
        XCTAssertEqual(bundle.extras.finalCutGrade?.members.count, 1)
    }

    func testInitialCutRequestCarriesReviewStage() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"empty":true,"slug":"initial-cut","isProducer":true,"canUpload":false,"canComment":false}}"#.utf8)) }
        _ = try await GroupReviewService(client: client()).stage("initial-cut", rowId: "r1", reviewStage: 2)
        XCTAssertEqual(StubProtocol.lastRequest?.url?.query, "stage=initial-cut&rowId=r1&reviewStage=2")
    }

    func testDecisionPostsToApprovalRoute() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"stage":"ADVISER_REVIEW"}}"#.utf8)) }
        try await GroupReviewService(client: client()).decideCut(rowId: "r1", .approveAnyway)
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/package-progress/r1/approval")
        XCTAssertEqual(String(data: request.httpBody ?? Data(), encoding: .utf8), #"{"action":"APPROVE_ANYWAY"}"#)
    }

    // MARK: Deep links

    func testGroupDeepLinks() {
        XCTAssertEqual(WorkRoute.deepLink(["groups"], []), DeepLinkMatch(tab: .work, route: nil))
        XCTAssertEqual(WorkRoute.deepLink(["groups", "r1"], []), DeepLinkMatch(tab: .work, route: .work(.group(rowId: "r1", stage: nil))))
        XCTAssertEqual(WorkRoute.deepLink(["groups", "r1", "initial-stage-2"], []),
                       DeepLinkMatch(tab: .work, route: .work(.group(rowId: "r1", stage: "initial-stage-2"))))
        XCTAssertEqual(WorkRoute.deepLink(["groups", "r1", "final-cut"], []),
                       DeepLinkMatch(tab: .work, route: .work(.group(rowId: "r1", stage: "final-cut"))))
    }

    func testGroupStageSlugs() {
        XCTAssertEqual(GroupStage(slug: "initial-stage-3"), .initialCut)
        XCTAssertEqual(GroupStage(slug: "initial-cut"), .initialCut)
        XCTAssertEqual(GroupStage(slug: "pitching"), .pitching)
        XCTAssertNil(GroupStage(slug: "contact"))
        XCTAssertEqual(GroupStageScreen.reviewStage(fromSlug: "initial-stage-2"), 2)
        XCTAssertNil(GroupStageScreen.reviewStage(fromSlug: "initial-stage-9"))
        XCTAssertNil(GroupStageScreen.reviewStage(fromSlug: "initial-cut"))
    }
}
