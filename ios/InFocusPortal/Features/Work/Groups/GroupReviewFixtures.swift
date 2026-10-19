import Foundation

/// Fictional Groups review data for the sample app and screenshots. Placeholder people only.
enum GroupReviewFixtures {
    static func bundle(_ slug: String) -> GroupStageBundle {
        let view = WorkStub.stage(slug, producer: true)
        guard slug == GroupStage.finalCut.rawValue else { return GroupStageBundle(view: view, extras: .none) }
        return GroupStageBundle(view: view, extras: GroupStageExtras(canGradeFinalCut: true, finalCutGrade: finalCutGrade,
                                                                    packageOfCycle: packageOfCycle, canEditToss: true,
                                                                    row: .init(packageOfCycleAt: nil)))
    }

    static let notes = [
        GroupNote(id: "n1", body: "Tighten the open: start on the interview, then cut to the Quad.",
                  createdAt: WorkStub.now.addingTimeInterval(-7_200), resolvedAt: nil, reviewHref: nil,
                  author: .init(userId: "u-sage", name: "Sage", email: "sage@example.edu")),
        GroupNote(id: "n2", body: GroupNote.wrapClip("m1", "Audio dips at the start of this clip."),
                  createdAt: WorkStub.now.addingTimeInterval(-3_600), resolvedAt: nil, reviewHref: nil,
                  author: .init(userId: "u-sage", name: "Sage", email: "sage@example.edu")),
    ]

    static let rosterNotes = "Ask the club president about the new booth layout."

    static let packageOfCycle = PackageOfCyclePanel(canVote: true, myVote: false, awardedAt: nil, blockedReason: nil, graders: [
        .init(userId: "u-sage", name: "Sage", voted: true),
        .init(userId: "u-kai", name: "Kai", voted: false),
    ])

    static let finalCutGrade = FinalCutGrade(
        canGrade: true, complete: false, viewerUserId: "u-kai",
        deadlineAt: WorkStub.day(-3), turnedInAt: WorkStub.day(-1), extensionDays: 0, daysLate: 2, penaltyMultiplier: 0.2,
        blocksSecondRevision: false, secondRevisionEligible: false, feedback: "", published: false, publishedAt: nil,
        members: [member("u-abby", "Abby"), member("u-otto", "Otto")],
        graders: [
            .init(userId: "u-sage", name: "Sage", email: "sage@example.edu", required: true, scoredCount: 2),
            .init(userId: "u-kai", name: "Kai", email: "kai@example.edu", required: true, scoredCount: 0),
        ]
    )

    static func member(_ id: String, _ name: String) -> FinalCutMemberGrade {
        FinalCutMemberGrade(userId: id, name: name, email: "\(name.lowercased())@example.edu", myQuality: nil, myEffort: nil,
                            locked: false, complete: false, pendingCount: 1, qualityAverage: nil, effortAverage: nil, average: nil,
                            afterRevisionCap: nil, revisionCapped: false, officialPoints: nil, revisionCount: 0,
                            secondRevisionEligible: false, daysLate: 2, penaltyMultiplier: 0.2, automaticPenaltyMultiplier: 0.2,
                            latePenaltyPercent: nil, graderScores: [
                                .init(userId: "u-sage", name: "Sage", required: true, quality: 21, effort: 23),
                                .init(userId: "u-kai", name: "Kai", required: true, quality: nil, effort: nil),
                            ])
    }
}
