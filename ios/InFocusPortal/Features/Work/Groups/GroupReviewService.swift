import Foundation

/// Every Portal call the Groups review pages make, matching the website's Groups stage pages
/// (`app/(app)/groups/[rowId]/…`, `components/package-stages/…`). The server decides who may
/// act; these calls only send what the website sends. In the sample app (`SampleMode`, or
/// DEBUG `-InFocusWorkStub`) it answers from fictional fixtures.
struct GroupReviewService {
    let client: PortalClient

    static var stubbed: Bool { SampleMode.isOn || UserDefaults.standard.bool(forKey: "InFocusWorkStub") }

    // MARK: Stage view

    /// One stage of one package, with the producer extras (grading, Package of the Cycle, toss).
    func stage(_ slug: String, rowId: String, reviewStage: Int?) async throws -> GroupStageBundle {
        if Self.stubbed { return GroupReviewFixtures.bundle(slug) }
        var query = [URLQueryItem(name: "stage", value: slug), URLQueryItem(name: "rowId", value: rowId)]
        if let reviewStage { query.append(URLQueryItem(name: "reviewStage", value: String(reviewStage))) }
        let data = try await client.send("GET", "api/package-cycle/stage", query: query)
        return GroupStageBundle(view: try client.decode(StageView.self, from: data),
                                extras: try client.decode(GroupStageExtras.self, from: data))
    }

    // MARK: Feedback notes

    func notes(rowId: String, stage: String) async throws -> [GroupNote] {
        if Self.stubbed { return GroupReviewFixtures.notes }
        let notes: GroupNotes = try await client.get("api/package-cycle/comments", query: [
            URLQueryItem(name: "rowId", value: rowId), URLQueryItem(name: "stage", value: stage),
        ])
        return notes.comments
    }

    /// Posts a note on a stage, or on one clip of it (`clipId`).
    func postNote(rowId: String, stage: String, body: String, clipId: String? = nil) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let rowId: String; let stage: String; let body: String }
        let text = clipId.map { GroupNote.wrapClip($0, body) } ?? body
        let _: PortalJSON.Empty = try await client.post("api/package-cycle/comments", body: Body(rowId: rowId, stage: stage, body: text))
    }

    func setResolved(noteId: String, resolved: Bool) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let id: String; let resolved: Bool }
        let _: PortalJSON.Empty = try await client.patch("api/package-cycle/comments", body: Body(id: noteId, resolved: resolved))
    }

    // MARK: Decisions

    /// Pitch, Contact (brainstorming) and A-roll/B-roll approve or undo, with the optional note.
    func setStageApproved(_ stage: GroupStage, rowId: String, approved: Bool, feedback: String) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let kind: String; let rowId: String; let approved: Bool; let feedback: String? }
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        let feedback = approved && !note.isEmpty ? note : nil
        switch stage {
        case .pitching:
            let _: PortalJSON.Empty = try await client.patch("api/package-cycle/stage",
                                                             body: Body(kind: "approve-pitching", rowId: rowId, approved: approved, feedback: feedback))
        case .aRoll:
            let _: PortalJSON.Empty = try await client.patch("api/package-cycle/stage",
                                                             body: Body(kind: "approve-aroll", rowId: rowId, approved: approved, feedback: feedback))
        case .brainstorming:
            let _: PortalJSON.Empty = try await client.patch("api/brainstorming",
                                                             body: Body(kind: "approve", rowId: rowId, approved: approved, feedback: feedback))
        case .initialCut, .finalCut:
            throw PortalError.server(status: 400, message: "This stage has its own decisions.")
        }
    }

    func decideCut(rowId: String, _ action: CutAction) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        let _: PortalJSON.Empty = try await client.post("api/package-progress/\(rowId)/approval", body: CutActionBody(action))
    }

    /// Send to (or remove from) the publishing queue.
    func setQueued(rowId: String, queued: Bool) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let rowId: String; let queued: Bool }
        let _: PortalJSON.Empty = try await client.post("api/package-cycle/queue", body: Body(rowId: rowId, queued: queued))
    }

    // MARK: Final Cut

    func saveScores(rowId: String, scores: [FinalCutScoreInput]) async throws -> FinalCutScoreResult {
        if Self.stubbed { SampleMode.notSaved(); return FinalCutScoreResult(savedCount: 0, gradedCount: 0, complete: false) }
        struct Body: Encodable { let rowId: String; let scores: [FinalCutScoreInput] }
        return try await client.post("api/package-cycle/grade", body: Body(rowId: rowId, scores: scores))
    }

    /// An executive's late penalty for one member: 5/10/15/20/30, or nil for automatic.
    func setLatePenalty(rowId: String, memberUserId: String, percent: Int?) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        let _: PortalJSON.Empty = try await client.patch("api/package-cycle/grade",
                                                         body: PenaltyBody(rowId: rowId, memberUserId: memberUserId, percent: percent))
    }

    func saveCycleFeedback(rowId: String, feedback: String) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let rowId: String; let feedback: String }
        let _: PortalJSON.Empty = try await client.post("api/package-cycle/grade/feedback", body: Body(rowId: rowId, feedback: feedback))
    }

    func publishGrades(rowId: String, feedback: String) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let rowId: String; let feedback: String }
        let _: PortalJSON.Empty = try await client.post("api/package-cycle/grade/publish", body: Body(rowId: rowId, feedback: feedback))
    }

    func saveToss(rowId: String, toss: String) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let rowId: String; let toss: String }
        let _: PortalJSON.Empty = try await client.post("api/package-cycle/toss", body: Body(rowId: rowId, toss: toss))
    }

    func votePackageOfCycle(rowId: String, vote: Bool) async throws -> PackageOfCyclePanel {
        if Self.stubbed { SampleMode.notSaved(); return GroupReviewFixtures.packageOfCycle }
        struct Body: Encodable { let rowId: String; let vote: Bool }
        return try await client.post("api/package-cycle/package-of-cycle", body: Body(rowId: rowId, vote: vote))
    }

    /// A member's Package of the Cycle certificate (PNG), saved to a temporary file to share.
    func certificate(rowId: String, memberId: String, name: String) async throws -> URL {
        if Self.stubbed { throw PortalError.sampleApp }
        let data = try await client.send("GET", "api/package-cycle/package-of-cycle/certificate", query: [
            URLQueryItem(name: "rowId", value: rowId), URLQueryItem(name: "memberId", value: memberId),
        ])
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Package of the Cycle - \(safe).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Group notes

    func rosterNotes(rowId: String) async throws -> String {
        if Self.stubbed { return GroupReviewFixtures.rosterNotes }
        let notes: GroupRosterNotes = try await client.get("api/package-progress/\(rowId)/notes")
        return notes.possibleIdeas ?? ""
    }

    func saveRosterNotes(rowId: String, text: String) async throws -> String {
        if Self.stubbed { SampleMode.notSaved(); return text }
        let notes: GroupRosterNotes = try await client.patch("api/package-progress/\(rowId)/notes",
                                                             body: GroupRosterNotes(possibleIdeas: text))
        return notes.possibleIdeas ?? ""
    }
}

/// `POST api/package-progress/<rowId>/approval` bodies, as the website's decision bar sends them.
struct CutActionBody: Encodable, Equatable {
    let action: String
    var approved: Bool?
    var note: String?
    var mediaVersionId: String?

    init(_ action: CutAction) {
        switch action {
        case .approve(let note, let versionId):
            self.action = "DECIDE"
            approved = true
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            self.note = trimmed.isEmpty ? nil : trimmed
            mediaVersionId = versionId
        case .needsRevisions(let versionId):
            self.action = "SUBMIT_REVIEW"
            mediaVersionId = versionId
        case .unapprove:
            self.action = "UNAPPROVE"
        case .approveAnyway:
            self.action = "APPROVE_ANYWAY"
        }
    }
}

/// `PATCH api/package-cycle/grade`: `percent` is sent as `null` for automatic (the key must be present).
struct PenaltyBody: Encodable, Equatable {
    let rowId: String
    let memberUserId: String
    let percent: Int?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rowId, forKey: .rowId)
        try container.encode(memberUserId, forKey: .memberUserId)
        try container.encode(percent, forKey: .percent)
    }

    private enum CodingKeys: String, CodingKey { case rowId, memberUserId, percent }
}
