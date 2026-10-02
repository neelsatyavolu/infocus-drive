import Foundation

/// Every Portal call the Grade Editor makes: the same endpoints and bodies as the
/// web Grade Editor and Participation pages. In a DEBUG stub session
/// (`-InFocusStubSession`) it answers from fictional fixtures instead.
struct GradeEditorService {
    let client: PortalClient

    private static let admin = "api/grades/admin"

    // MARK: Reads

    func cycle(_ cycleNumber: Int?) async throws -> CycleGrades {
        #if DEBUG
        if Self.stubbed { return try GradeEditorFixtures.cycle(cycleNumber ?? 2) }
        #endif
        let query = cycleNumber.map { [URLQueryItem(name: "cycle", value: String($0))] } ?? []
        return try await client.get(Self.admin, query: query)
    }

    func totals() async throws -> GradeTotals {
        #if DEBUG
        if Self.stubbed { return try GradeEditorFixtures.decode(GradeTotals.self, GradeEditorFixtures.totalsJSON) }
        #endif
        return try await client.get(Self.admin, query: [URLQueryItem(name: "view", value: "totals")])
    }

    func missing() async throws -> MissingGrades {
        #if DEBUG
        if Self.stubbed { return try GradeEditorFixtures.decode(MissingGrades.self, GradeEditorFixtures.missingJSON) }
        #endif
        return try await client.get(Self.admin, query: [URLQueryItem(name: "view", value: "missing")])
    }

    func gradebook(userId: String) async throws -> StudentGradebook {
        #if DEBUG
        if Self.stubbed { return try GradeEditorFixtures.gradebook(userId) }
        #endif
        return try await client.get(Self.admin, query: [URLQueryItem(name: "view", value: "student"),
                                                         URLQueryItem(name: "userId", value: userId)])
    }

    func participation(weekStart: String) async throws -> ParticipationWeek {
        #if DEBUG
        if Self.stubbed { return try GradeEditorFixtures.participation(weekStart) }
        #endif
        return try await client.get("api/participation", query: [URLQueryItem(name: "weekStart", value: weekStart)])
    }

    func participationRequests() async throws -> ParticipationRequests {
        #if DEBUG
        if Self.stubbed { return try GradeEditorFixtures.decode(ParticipationRequests.self, GradeEditorFixtures.requestsJSON) }
        #endif
        return try await client.get("api/participation/requests")
    }

    // MARK: Writes (`POST api/grades/admin`, one action each)

    /// Final Cut score or state, feedback and turned-in date for one person and cycle.
    func save(_ body: SaveGradeBody) async throws -> CycleGradeRow {
        if Self.stubbed { return try GradeEditorFixtures.saved(body) }
        return try await client.post(Self.admin, body: body)
    }

    func setPublished(cycleNumber: Int, userId: String, published: Bool) async throws {
        if Self.stubbed { return }
        let _: PortalJSON.Empty = try await client.post(Self.admin, body: PublishBody(cycleNumber: cycleNumber, userId: userId,
                                                                                         published: published))
    }

    func setCheckIn(cycleNumber: Int, userId: String, stage: CheckInStage, points: CheckInPoints?) async throws {
        if Self.stubbed { return }
        let _: PortalJSON.Empty = try await client.post(Self.admin, body: CheckInBody(userId: userId, cycleNumber: cycleNumber,
                                                                                         stage: stage, points: points))
    }

    func setTotalNotes(userId: String, notes: String) async throws {
        if Self.stubbed { return }
        let _: PortalJSON.Empty = try await client.post(Self.admin, body: TotalNotesBody(userId: userId, notes: notes))
    }

    func saveParticipation(_ entries: [ParticipationEntryBody]) async throws -> ParticipationSaveResult {
        if Self.stubbed {
            return ParticipationSaveResult(saved: entries.count, pending: false, itemCount: 0)
        }
        return try await client.post("api/participation", body: ParticipationBody(entries: entries))
    }

    /// Approve or deny another producer's docked scores.
    func decideParticipation(requestId: String, approved: Bool) async throws {
        if Self.stubbed { return }
        let _: PortalJSON.Empty = try await client.patch("api/participation/requests",
                                                         body: ParticipationDecision(requestId: requestId, approved: approved))
    }

    static var stubbed: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: "InFocusStubSession") != nil
        #else
        false
        #endif
    }
}

// MARK: Bodies (`app/api/grades/admin/route.ts`, `app/api/participation/*`)

/// The web's autosave: score or state, feedback and turned-in date (teamwork is always 0).
struct SaveGradeBody: Encodable, Equatable {
    var action = "save"
    let cycleNumber: Int
    let userId: String
    /// Nil with a state (ungraded/exempt).
    let effortPoints: Int?
    let finalCutState: ScoreState?
    var teamworkPoints = 0
    let feedback: String
    /// `YYYY-MM-DD`, or nil to clear.
    let turnedInDate: String?

    init(cycleNumber: Int, userId: String, finalCut: GradeEditorLogic.FinalCutInput, feedback: String, turnedInDate: String?) {
        self.cycleNumber = cycleNumber
        self.userId = userId
        switch finalCut {
        case .points(let points):
            effortPoints = points
            finalCutState = nil
        case .state(let state):
            effortPoints = nil
            finalCutState = state
        }
        self.feedback = String(feedback.prefix(GradeEditorLogic.maxFeedback))
        self.turnedInDate = turnedInDate
    }

    // Explicit nulls: the Portal reads a missing turnedInDate as "keep", null as "clear".
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(cycleNumber, forKey: .cycleNumber)
        try container.encode(userId, forKey: .userId)
        try container.encode(effortPoints, forKey: .effortPoints)
        try container.encode(finalCutState, forKey: .finalCutState)
        try container.encode(teamworkPoints, forKey: .teamworkPoints)
        try container.encode(feedback, forKey: .feedback)
        try container.encode(turnedInDate, forKey: .turnedInDate)
    }

    private enum CodingKeys: String, CodingKey {
        case action, cycleNumber, userId, effortPoints, finalCutState, teamworkPoints, feedback, turnedInDate
    }
}

struct PublishBody: Encodable, Equatable {
    var action = "setPublish"
    let cycleNumber: Int
    let userId: String
    let published: Bool
}

struct CheckInBody: Encodable, Equatable {
    var action = "setCheckIn"
    let userId: String
    let cycleNumber: Int
    let stage: CheckInStage
    /// Nil returns the cell to its automatic score.
    let points: CheckInPoints?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(userId, forKey: .userId)
        try container.encode(cycleNumber, forKey: .cycleNumber)
        try container.encode(stage, forKey: .stage)
        try container.encode(points, forKey: .points)
    }

    private enum CodingKeys: String, CodingKey { case action, userId, cycleNumber, stage, points }
}

struct TotalNotesBody: Encodable, Equatable {
    var action = "setTotalNotes"
    let userId: String
    let notes: String
}

struct ParticipationBody: Encodable, Equatable {
    let entries: [ParticipationEntryBody]
}

struct ParticipationDecision: Encodable, Equatable {
    let requestId: String
    let approved: Bool
}
