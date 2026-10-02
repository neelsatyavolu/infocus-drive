import Foundation

/// Fictional data for the App Review sample app (`SampleMode`) and screenshots: no Portal, no real people.
extension WorkAPI {
    static let stub = WorkAPI(
        home: { WorkStub.home },
        gates: { WorkStub.gates },
        stage: { slug, rowId, _ in WorkStub.stage(slug, producer: rowId != nil) },
        groups: { _ in WorkStub.groups },
        brainstorm: { _ in WorkStub.brainstorm },
        comments: { _, _ in StageComments(comments: WorkStub.comments, unread: 0) },
        postComment: { _, _, _ in SampleMode.notSaved() },
        decide: { _ in SampleMode.notSaved() },
        saveDocLink: { _, _ in SampleMode.notSaved() },
        uploadProof: { _, _, _ in SampleMode.notSaved() },
        startUpload: { _ in throw PortalError.sampleApp },
        finishUpload: { _, _ in SampleMode.notSaved() },
        data: { _ in Data() }
    )
}

enum WorkStub {
    static let now = Date()
    static func day(_ offset: Int) -> Date { Calendar.current.date(byAdding: .day, value: offset, to: now)! }

    static let abby = PackagePerson(userId: "u-abby", name: "Abby", email: "abby@example.edu")
    static let otto = PackagePerson(userId: "u-otto", name: "Otto", email: "otto@example.edu")
    static let sage = PackagePerson(userId: "u-sage", name: "Sage", email: "sage@example.edu")

    static let home = HomePayload(
        upNext: UpNext(cycleNumber: 2, groupTopic: "Club Fair returns to the Quad", finalCutDate: day(9),
                       producerName: "Otto", memberNames: ["Abby", "Sage"], checkInsDone: 2, checkInsTotal: 4,
                       stages: [
                           DueStage(key: "proofOfContact", label: "Proof of contact", done: true, dueDate: day(-6)),
                           DueStage(key: "aRollBRoll", label: "A-roll/B-roll", done: true, dueDate: day(-1)),
                           DueStage(key: "initialCut", label: "Initial Cut", done: false, dueDate: day(2)),
                           DueStage(key: "finalCut", label: "Final Cut", done: false, dueDate: day(9)),
                       ]),
        activity: [
            ActivityEntry(id: "a1", actorName: "Abby", initials: "AB", verb: "uploaded", subject: "Interview with the club president",
                          createdAt: now.addingTimeInterval(-3_600 * 3)),
            ActivityEntry(id: "a2", actorName: "Sage", initials: "SA", verb: "commented on", subject: "B-roll of the Quad",
                          createdAt: now.addingTimeInterval(-3_600 * 26)),
        ],
        snapshot: GradeSnapshot(letter: "A-", percentage: 91.4, packages: .init(earned: 82, possible: 90),
                                participation: .init(earned: 46, possible: 50), livestreamHours: 5, requiredLivestreamHours: 8,
                                semesterLabel: "Semester 1", extensionsRemaining: 2.5, extensionBank: 4, unreadFeedback: 1),
        workspaces: [WorkspaceSummary(id: "w1", name: "Sample workspace", projects: [
            ProjectSummary(id: "p1", name: "Sample package: Club Fair", updatedAt: day(-1), mediaCount: 2),
        ])]
    )

    static let gates = StudentGates(
        cycleNumber: 2, hasRow: true,
        unlocked: ["a-roll": true, "initial-cut": true, "final-cut": false],
        statuses: ["brainstorming": .approved, "a-roll": .approved, "initial-cut": .needsRevisions, "final-cut": .locked],
        unread: ["brainstorming": 0, "a-roll": 0, "initial-cut": 2, "final-cut": 0]
    )

    static let row = StageRow(id: "row-1", cycleNumber: 2, groupTopic: "Club Fair returns to the Quad", headline: nil, toss: nil,
                              proofOfContact: true, aRollBRoll: true, aRollNeedsChanges: false, initialCut: false, finalCut: false,
                              awaitingRevisedInitialCut: false, initialCutNeedsRevisions: true, queuedForAirAt: nil,
                              approvalStage: "DRAFT", remainingExecutiveSignoffs: nil, assignedProducer: otto, members: [abby, sage])

    /// A producer (`rowId` given) may review; a student may upload.
    static func stage(_ slug: String, producer: Bool) -> StageView {
        let media = slug == "a-roll"
            ? [clip("m1", "Interview with the club president", "a-roll"), clip("m2", "Quad at lunch", "b-roll")]
            : [clip("m3", "Initial Cut Version 1", nil)]
        let approval = CutApproval(stage: "ASSOCIATE_REVIEW", canAct: true, canUnapprove: false, canApproveAnyway: false,
                                   awaitingRevisedInitialCut: false, remainingExecutiveSignoffs: 2)
        return StageView(empty: false, slug: slug, isProducer: producer, unlocked: true, canUpload: !producer, canComment: producer,
                         canApproveAroll: producer, allowSecondFinalCut: false,
                         cutApproval: producer && slug == "initial-cut" ? approval : nil, row: row, media: media)
    }

    static func clip(_ id: String, _ title: String, _ roll: String?) -> StageMedia {
        StageMedia(id: id, title: title, rollKind: roll, projectId: "p1", versionId: "v-\(id)", versionNumber: 1, status: "READY",
                   approvalStatus: "IN_REVIEW", approvedInStage: nil, thumbnailUrl: nil, playbackUrl: nil, commentCount: 1, isNew: false)
    }

    static let comments = [
        StageComment(id: "c1", body: "Tighten the open: start on the interview, then cut to the Quad.", createdAt: now.addingTimeInterval(-7_200),
                     author: .init(userId: "u-otto", name: "Otto", email: "otto@example.edu")),
    ]

    static let groups = GroupsPayload(
        activeCycleNumber: 2,
        cycles: [1, 2, 3].map { CycleInfo(cycleNumber: $0, focus: nil, dates: .init(pitching: nil, proofOfContact: nil, aRollBRoll: nil, initialCut: nil, finalCut: nil)) },
        rows: [
            group("g1", "Club Fair returns to the Quad", pitching: true, proof: true, aRoll: true, cut: "ASSOCIATE_REVIEW", producer: sage),
            group("g2", "Robotics team heads to state", pitching: true, proof: true, aRoll: false, cut: "DRAFT", producer: sage, aRollMedia: true),
            group("g3", "New library hours", pitching: false, proof: false, aRoll: false, cut: "DRAFT", producer: otto),
            group("g4", "Fall concert preview", pitching: true, proof: true, aRoll: true, cut: "APPROVED", producer: otto, queued: true),
        ]
    )

    static func group(_ id: String, _ topic: String, pitching: Bool, proof: Bool, aRoll: Bool, cut: String,
                      producer: PackagePerson, aRollMedia: Bool = false, queued: Bool = false) -> GroupRow {
        GroupRow(id: id, groupTopic: topic, groupType: "News", assignedProducerUserId: producer.userId, assignedProducer: producer,
                 assignedExecutiveProducerUserId: nil, assignedExecutiveProducer: nil, members: [abby, otto],
                 reviewReadyAt: .init(brainstorming: nil, aRoll: now.addingTimeInterval(-3_600 * 5), initialCut: now.addingTimeInterval(-3_600 * 20)),
                 pitching: pitching, proofOfContact: proof, aRollBRoll: aRoll, aRollHasMedia: aRollMedia || aRoll, aRollNeedsChanges: false,
                 initialCutMediaItemId: cut == "DRAFT" ? nil : "cut-\(id)", initialCutVersionNumber: cut == "DRAFT" ? nil : 1,
                 initialCutNeedsRevisions: false, awaitingRevisedInitialCut: false, approvalStage: cut, remainingExecutiveSignoffs: 2,
                 finalCutMediaItemId: queued ? "final-\(id)" : nil, queuedForAir: queued, finalCutGraded: false,
                 brainstormDocUrl: "", proofs: [], extensionDays: 0)
    }

    static let brainstorm = BrainstormPayload(activeCycleNumber: 2, packages: [
        BrainstormPackage(id: "row-1", cycleNumber: 2, groupTopic: "Club Fair returns to the Quad",
                          brainstormDocUrl: "https://docs.google.com/document/d/example", proofOfContact: false,
                          assignedProducer: otto, members: [abby, sage],
                          proofs: [ProofView(id: "pr1", slot: 1, fileName: "email.jpg", imageUrl: "/api/brainstorming/proofs/pr1/image")]),
    ])
}
