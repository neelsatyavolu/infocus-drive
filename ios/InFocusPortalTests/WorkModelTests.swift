import XCTest
@testable import InFocusPortal

/// Decoding the Portal's Work payloads (fixtures use placeholder people only).
final class WorkModelTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
    }

    func testDecodesHome() throws {
        let home = try decode(HomePayload.self, """
        {"data":{"upNext":{"cycleNumber":2,"groupTopic":"Club Fair","finalCutDate":"2026-10-09T00:00:00.000Z",
          "producerName":"Otto","memberNames":["Abby","Sage"],"checkInsDone":1,"checkInsTotal":4,
          "stages":[{"key":"proofOfContact","label":"Proof of contact","done":true,"dueDate":"2026-09-22T00:00:00.000Z"},
                    {"key":"aRollBRoll","label":"A-roll/B-roll","done":false,"dueDate":"2026-09-29T00:00:00.000Z"}]},
          "activity":[{"id":"e1","actorName":"Abby","actorEmail":"abby@example.edu","initials":"AB","verb":"uploaded",
                       "subject":"Interview v2","createdAt":"2026-10-01T18:00:00.000Z"}],
          "snapshot":{"letter":"A","percentage":93.5,"packages":{"earned":40,"possible":45},"participation":{"earned":48,"possible":50},
                      "livestreamHours":3,"requiredLivestreamHours":8,"livestreamPoints":null,"semesterLabel":"Semester 1",
                      "thisWeek":null,"extensionsRemaining":2.5,"extensionBank":4,"unreadFeedback":1},
          "workspaces":[{"id":"w1","name":"Sample","projects":[{"id":"p1","name":"Club Fair","updatedAt":"2026-10-01T00:00:00.000Z","mediaCount":2}]}]}}
        """)
        XCTAssertEqual(home.upNext?.nextStage?.key, "aRollBRoll")
        XCTAssertEqual(home.upNext?.nextStage?.studentStage, .aRoll)
        XCTAssertEqual(home.snapshot?.extensionsRemaining, 2.5)
        XCTAssertEqual(home.workspaces.first?.projects.first?.mediaCount, 2)
        XCTAssertEqual(home.activity.first?.verb, "uploaded")
    }

    func testDecodesSampleHomeWithoutPackage() throws {
        let home = try decode(HomePayload.self, #"{"data":{"upNext":null,"activity":[],"snapshot":null,"workspaces":[]}}"#)
        XCTAssertNil(home.upNext)
        XCTAssertNil(home.snapshot)
    }

    func testDecodesGatesAndToleratesNewStatuses() throws {
        let gates = try decode(StudentGates.self, """
        {"data":{"cycleNumber":2,"hasRow":true,"unlocked":{"a-roll":true,"initial-cut":false,"final-cut":false},
          "statuses":{"brainstorming":"approved","a-roll":"needs-revisions","initial-cut":"locked","final-cut":"something-new"},
          "remainingExecutiveSignoffs":2,"unread":{"brainstorming":0,"a-roll":3,"initial-cut":0,"final-cut":0}}}
        """)
        XCTAssertEqual(gates.status(.aRoll), .needsRevisions)
        XCTAssertEqual(gates.status(.finalCut), .unknown)
        XCTAssertTrue(gates.isUnlocked(.brainstorming))
        XCTAssertTrue(gates.isUnlocked(.aRoll))
        XCTAssertFalse(gates.isUnlocked(.initialCut))
        XCTAssertEqual(gates.unread["a-roll"], 3)
    }

    func testDecodesStageViewAndEmptyStage() throws {
        let view = try decode(StageView.self, """
        {"data":{"empty":false,"slug":"initial-cut","isProducer":true,"unlocked":true,"canUpload":false,"allowSecondFinalCut":false,
          "canComment":true,"cutApproval":{"progressRowId":"r1","stage":"ADVISER_REVIEW","controversial":false,"socialMedia":false,
            "remainingExecutiveSignoffs":2,"canAct":true,"canUnapprove":false,"canApproveAnyway":false,"awaitingRevisedInitialCut":false,"signoffs":[]},
          "canApproveAroll":false,"canGradeFinalCut":false,"finalCutGrade":null,"packageOfCycle":null,"canEditToss":false,
          "row":{"id":"r1","cycleNumber":2,"groupTopic":"Club Fair","headline":null,"toss":null,"packageOfCycleAt":null,
            "proofOfContact":true,"aRollBRoll":true,"aRollNeedsChanges":false,"initialCut":false,"finalCut":false,
            "awaitingRevisedInitialCut":false,"initialCutNeedsRevisions":false,"queuedForAirAt":null,"approvalStage":"ADVISER_REVIEW",
            "remainingExecutiveSignoffs":2,"assignedProducer":{"id":"u-otto","name":"Otto","email":"otto@example.edu"},
            "members":[{"userId":"u-abby","name":"Abby","email":"abby@example.edu"}]},
          "media":[{"id":"m1","title":"Initial Cut Version 2","rollKind":null,"projectId":"p1","versionId":"v2","versionNumber":2,
            "status":"READY","approvalStatus":"IN_REVIEW","approvedInStage":null,"thumbnailUrl":"https://drive.example.edu/t.jpg",
            "playbackUrl":"https://drive.example.edu/v.mp4","commentCount":3,"isNew":false}]}}
        """)
        XCTAssertEqual(view.cutApproval?.canAct, true)
        XCTAssertEqual(view.media?.first?.playbackUrl?.host, "drive.example.edu")
        XCTAssertEqual(view.row?.memberNames, "Abby")

        let empty = try decode(StageView.self, #"{"data":{"empty":true,"slug":"a-roll","isProducer":false,"canUpload":false,"canComment":false}}"#)
        XCTAssertTrue(empty.empty)
        XCTAssertNil(empty.row)
    }

    func testDecodesGroupsRow() throws {
        let payload = try decode(GroupsPayload.self, """
        {"data":{"canEdit":false,"activeCycleNumber":2,"producers":[],"executives":[],"previousTeammatesByUser":{},
          "cycles":[{"cycleNumber":2,"focus":null,"dates":{"pitching":null,"proofOfContact":"2026-09-22T00:00:00.000Z","aRollBRoll":null,"initialCut":null,"finalCut":null}}],
          "rows":[{"id":"g1","reviewReadyAt":{"brainstorming":null,"a-roll":"2026-10-01T12:00:00.000Z","initial-cut":null},
            "groupMembers":"","groupTopic":"Club Fair","groupType":"News","category":null,"assignedProducerUserId":"u-sage",
            "assignedProducer":{"userId":"u-sage","name":"Sage","email":"sage@example.edu"},"assignedExecutiveProducerUserId":null,
            "assignedExecutiveProducer":null,"memberUserIds":["u-abby"],"members":[{"userId":"u-abby","name":"Abby","email":"abby@example.edu"}],
            "projectId":null,"initialCutMediaItemId":null,"finalCutMediaItemId":null,"pitching":true,"proofOfContact":true,"aRollBRoll":false,
            "initialCut":false,"initialCutManual":false,"revisedInitialCut":false,"finalCut":false,"finalCutManual":false,"extension":false,
            "extensionDays":1.5,"groupWideExtension":false,"possibleInterviews":"","possibleIdeas":"","notes":"","stageNotes":null,
            "brainstormDocUrl":"","proofs":[],"approvalStage":"DRAFT","remainingExecutiveSignoffs":2,"awaitingRevisedInitialCut":false,
            "initialCutVersionNumber":null,"initialCutNeedsRevisions":false,"initialCutReviewStage":null,"aRollHasMedia":true,
            "aRollNeedsChanges":false,"queuedForAir":false,"finalCutGraded":false,"finalCutGradesPublished":false,
            "finalCutSubmittedAt":null,"packageOfCycleAt":null,"finalCutScoredByUserIds":[]}]}}
        """)
        let row = try XCTUnwrap(payload.rows.first)
        XCTAssertNotNil(row.reviewReadyAt?.aRoll)
        XCTAssertEqual(row.extensionDays, 1.5)
        XCTAssertTrue(row.isAssigned(toEmail: "SAGE@example.edu"))
        XCTAssertEqual(GroupStage.current(for: row), .aRoll)
    }

    func testDecodesCommentsAndBrainstorm() throws {
        let comments = try decode(StageComments.self, """
        {"data":{"comments":[{"id":"c1","rowId":"r1","stage":"a-roll","body":"Reshoot the wide.","createdAt":"2026-10-01T18:00:00.000Z",
          "reviewHref":null,"author":{"userId":"u-otto","name":"Otto","email":"otto@example.edu"}}],"unread":0}}
        """)
        XCTAssertEqual(comments.comments.first?.authorName, "Otto")
        let brainstorm = try decode(BrainstormPayload.self, """
        {"data":{"currentUserId":"u-abby","canApprove":false,"activeCycleNumber":2,"cycles":[{"cycleNumber":2,"focus":null}],
          "packages":[{"id":"r1","cycleNumber":2,"groupTopic":"Club Fair","brainstormDocUrl":"https://docs.google.com/document/d/x",
            "proofOfContact":false,"assignedProducer":null,"members":[],
            "proofs":[{"id":"p2","slot":2,"fileName":"b.jpg","mimeType":"image/jpeg","imageUrl":"/api/brainstorming/proofs/p2/image"}]}]}}
        """)
        XCTAssertEqual(brainstorm.packages.first?.proof(in: 2)?.id, "p2")
        XCTAssertNil(brainstorm.packages.first?.proof(in: 1))
    }

    func testUploadTicket() throws {
        let ticket = try decode(StageUploadTicket.self, """
        {"data":{"mediaId":"m1","versionId":"v1","nextVersion":1,"upload":{"provider":"NAS","uploadUrl":"https://drive.example.edu/api/upload",
          "path":"Package Storage/x.mov","token":"t","signature":"s","expiresAt":1,"videoId":"nas:1"}}}
        """)
        XCTAssertEqual(ticket.upload.token, "t")
        XCTAssertEqual(DriveUploader.serviceURL(ticket.upload.uploadUrl, "chunk", ["index": "3", "upload_id": "u"]).absoluteString,
                       "https://drive.example.edu/api/upload/chunk?index=3&upload_id=u")
    }
}
