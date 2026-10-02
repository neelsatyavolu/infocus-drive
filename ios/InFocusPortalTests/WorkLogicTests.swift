import XCTest
@testable import InFocusPortal

/// Work logic that must match the Portal: tile labels, visibility, deadlines, uploads, decisions.
final class WorkLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(pitching: Bool = true, proof: Bool = true, aRoll: Bool = true, stage: String = "DRAFT",
                     cut: String? = nil, aRollMedia: Bool = false, needsChanges: Bool = false, proofs: Int = 0,
                     doc: String = "", producer: String? = "sage@example.edu", queued: Bool = false,
                     graded: Bool = false, remaining: Int? = 2, readyAt: Date? = nil) -> GroupRow {
        GroupRow(id: "g", groupTopic: "Club Fair", groupType: "News", assignedProducerUserId: producer == nil ? nil : "u",
                 assignedProducer: producer.map { PackagePerson(userId: "u", name: "Sage", email: $0) },
                 assignedExecutiveProducerUserId: nil, assignedExecutiveProducer: nil, members: [],
                 reviewReadyAt: .init(brainstorming: readyAt, aRoll: readyAt, initialCut: readyAt),
                 pitching: pitching, proofOfContact: proof, aRollBRoll: aRoll, aRollHasMedia: aRollMedia, aRollNeedsChanges: needsChanges,
                 initialCutMediaItemId: cut, initialCutVersionNumber: cut == nil ? nil : 2, initialCutNeedsRevisions: false,
                 awaitingRevisedInitialCut: false, approvalStage: stage, remainingExecutiveSignoffs: remaining,
                 finalCutMediaItemId: queued ? "f" : nil, queuedForAir: queued, finalCutGraded: graded, brainstormDocUrl: doc,
                 proofs: (0..<proofs).map { ProofView(id: "p\($0)", slot: $0 + 1, fileName: "p.jpg", imageUrl: "/x") },
                 extensionDays: nil)
    }

    func testTileStatusFollowsThePortal() {
        XCTAssertEqual(GroupTileStatus.of(row(pitching: false)).label, "Pitch Pending")
        XCTAssertEqual(GroupTileStatus.of(row(proof: false)).label, "Brainstorming")
        let ready = GroupTileStatus.of(row(proof: false, proofs: 3, doc: "https://docs.google.com/d/x",
                                           readyAt: now.addingTimeInterval(-5 * 3_600)), now: now)
        XCTAssertEqual(ready, GroupTileStatus(label: "Brainstorm Pending Review for 5h", tone: .warning))
        XCTAssertEqual(GroupTileStatus.of(row(aRoll: false, aRollMedia: true, needsChanges: true)).tone, .danger)
        XCTAssertEqual(GroupTileStatus.of(row(aRoll: false)).label, "A-roll/B-roll Pending")
        XCTAssertEqual(GroupTileStatus.of(row(stage: "DRAFT")).label, "Initial Cut Pending")
        XCTAssertEqual(GroupTileStatus.of(row(stage: "DRAFT", cut: "c")).label, "Initial Cut Version 2 Needs Revisions")
        XCTAssertEqual(GroupTileStatus.of(row(stage: "ADVISER_REVIEW", cut: "c")).label, "Waiting for the adviser (Stage 2)")
        XCTAssertEqual(GroupTileStatus.of(row(stage: "EXECUTIVE_REVIEW", cut: "c", remaining: 1)).label, "1 exec left")
        XCTAssertEqual(GroupTileStatus.of(row(stage: "ASSOCIATE_REVIEW", cut: "c")).label, "Initial Cut V2 Pending Review")
        XCTAssertEqual(GroupTileStatus.of(row(stage: "APPROVED", queued: true, graded: true)).label, "Final Cut Graded")
        XCTAssertEqual(GroupTileStatus.of(row(stage: "APPROVED")).label, "Final Cut Pending")
    }

    func testAssociatesSeeOnlyTheirGroups() {
        let associate = PortalUser(email: "sage@example.edu", name: "Sage", role: .associateProducer, onStudentPackage: false)
        let mine = row(producer: "sage@example.edu"), theirs = row(producer: "otto@example.edu"), open = row(producer: nil)
        XCTAssertEqual(GroupsVisibility.visible([mine, theirs, open], for: associate).count, 2)
        XCTAssertTrue(GroupsVisibility.isPrimary(mine, for: associate))
        XCTAssertFalse(GroupsVisibility.isPrimary(open, for: associate))

        let adviser = PortalUser(email: "adviser@example.edu", name: "Adviser", role: .adviser, onStudentPackage: false)
        XCTAssertEqual(GroupsVisibility.visible([mine, theirs, open], for: adviser).count, 3)
        XCTAssertTrue(GroupsVisibility.isPrimary(row(stage: "ADVISER_REVIEW", producer: "otto@example.edu"), for: adviser))
        let executive = PortalUser(email: "exec@example.edu", name: "Exec", role: .executiveProducer, onStudentPackage: false)
        XCTAssertFalse(GroupsVisibility.isPrimary(row(stage: "ADVISER_REVIEW", producer: "otto@example.edu"), for: executive))
        XCTAssertTrue(GroupsVisibility.isPrimary(row(stage: "EXECUTIVE_REVIEW", producer: "otto@example.edu"), for: executive))
    }

    func testDeadlinesCloseAt1159PacificOnTheirDate() throws {
        let stored = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-29T00:00:00Z"))
        let close = Deadline.close(onDayOf: stored)
        XCTAssertEqual(ISO8601DateFormatter().string(from: close), "2026-09-30T06:59:00Z") // PDT is UTC-7
        XCTAssertEqual(Deadline.remaining(until: close, now: close.addingTimeInterval(-(2 * 86_400 + 4 * 3_600))), "2d 4h")
        XCTAssertEqual(Deadline.remaining(until: close, now: close.addingTimeInterval(-90)), "1m")
        XCTAssertNil(Deadline.remaining(until: close, now: close.addingTimeInterval(1)))
    }

    func testChunkSizesCoverTheFile() {
        let size = 40 * 1024 * 1024, piece = DriveUploader.chunkSize
        let total = Int((Double(size) / Double(piece)).rounded(.up))
        let lengths = (0..<total).map { DriveUploader.pieceLength(index: $0, pieceSize: piece, total: total, size: size) }
        XCTAssertEqual(lengths, [piece, piece, 8 * 1024 * 1024])
        XCTAssertEqual(lengths.reduce(0, +), size)
    }

    func testMultipartAndProofBodies() {
        let fields = String(decoding: Multipart.fields(["token": "t", "path": "a/b"], boundary: "B"), as: UTF8.self)
        XCTAssertTrue(fields.contains("name=\"path\"\r\n\r\na/b\r\n"))
        XCTAssertTrue(fields.hasSuffix("--B--\r\n"))
        let proof = String(decoding: ProofUpload.body(rowId: "r1", slot: 2, jpeg: Data("JPEG".utf8), boundary: "B"), as: UTF8.self)
        XCTAssertTrue(proof.contains("name=\"slot\"\r\n\r\n2\r\n"))
        XCTAssertTrue(proof.contains("filename=\"proof-2.jpg\""))
    }

    func testPackageTextRules() {
        XCTAssertNotNil(PackageText.headlineError(" "))
        XCTAssertNotNil(PackageText.headlineError("A <b> headline"))
        XCTAssertNil(PackageText.headlineError("Club Fair returns"))
        XCTAssertNotNil(PackageText.tossError("Up next [INSERT]"))
        XCTAssertNil(PackageText.tossError("Up next, Abby reports from the Quad."))
        XCTAssertNotNil(PackageText.rollSizeError(kind: "b-roll", bytes: 16 * 1_073_741_824))
        XCTAssertNil(PackageText.rollSizeError(kind: "a-roll", bytes: 16 * 1_073_741_824))
        XCTAssertTrue(GoogleDocLink.isValid("https://docs.google.com/document/d/x"))
        XCTAssertFalse(GoogleDocLink.isValid("http://docs.google.com/document/d/x"))
    }

    func testStageSlugsAndDeepLinks() {
        XCTAssertEqual(GroupStage(slug: "initial-stage-2"), .initialCut)
        XCTAssertEqual(GroupStageScreen.reviewStage(fromSlug: "initial-stage-3"), 3)
        XCTAssertNil(GroupStageScreen.reviewStage(fromSlug: "a-roll"))
        let match = WorkRoute.deepLink(["groups", "row1", "initial-stage-2"], [])
        XCTAssertEqual(match?.route, .work(.group(rowId: "row1", stage: "initial-stage-2")))
    }
}

/// The approve / send-back requests go to the website's routes.
final class WorkDecisionTests: XCTestCase {
    private func client() -> PortalClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return PortalClient(portal: URL(string: "https://portal.example.edu")!, session: URLSession(configuration: config), cookies: { [] })
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    private func body() throws -> [String: Any] {
        let data = try XCTUnwrap(StubProtocol.lastRequest?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPitchApprovalWithFeedback() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"ok":true}}"#.utf8)) }
        try await WorkDecisions.send(StageDecision(rowId: "r1", stage: .pitching, approved: true, feedback: "  Great angle. "), client: client())
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/package-cycle/stage")
        let sent = try body()
        XCTAssertEqual(sent["kind"] as? String, "approve-pitching")
        XCTAssertEqual(sent["feedback"] as? String, "Great angle.")
    }

    func testBrainstormSkipSendsNoFeedback() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{}}"#.utf8)) }
        try await WorkDecisions.send(StageDecision(rowId: "r1", stage: .brainstorming, approved: true), client: client())
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/brainstorming")
        let sent = try body()
        XCTAssertEqual(sent["kind"] as? String, "approve")
        XCTAssertNil(sent["feedback"])
    }

    func testInitialCutSendBack() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{}}"#.utf8)) }
        try await WorkDecisions.send(StageDecision(rowId: "r1", stage: .initialCut, approved: false, feedback: "Trim the open",
                                                   mediaVersionId: "v2"), client: client())
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/package-progress/r1/approval")
        let sent = try body()
        XCTAssertEqual(sent["action"] as? String, "DECIDE")
        XCTAssertEqual(sent["approved"] as? Bool, false)
        XCTAssertEqual(sent["mediaVersionId"] as? String, "v2")
        XCTAssertEqual(sent["note"] as? String, "Trim the open")
    }

    func testServerRefusalSurfacesItsMessage() async {
        StubProtocol.handler = { _ in (403, Data(#"{"error":{"message":"Only the assigned producer can approve."}}"#.utf8)) }
        do {
            try await WorkDecisions.send(StageDecision(rowId: "r1", stage: .aRoll, approved: true), client: client())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Only the assigned producer can approve.")
        }
    }
}
