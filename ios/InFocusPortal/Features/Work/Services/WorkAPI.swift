import Foundation
import SwiftUI

/// Every Portal call the Work area makes, in one place. Screens build it from
/// the environment's client (`workAPI(client)`); the sample app swaps in
/// fixtures (`SampleMode`), so no screen ever needs a live Portal to render.
struct WorkAPI: Sendable {
    var home: @Sendable () async throws -> HomePayload
    var gates: @Sendable () async throws -> StudentGates
    var stage: @Sendable (_ slug: String, _ rowId: String?, _ reviewStage: Int?) async throws -> StageView
    var groups: @Sendable (_ cycle: Int?) async throws -> GroupsPayload
    var brainstorm: @Sendable (_ cycle: Int?) async throws -> BrainstormPayload
    var comments: @Sendable (_ rowId: String, _ stage: String) async throws -> StageComments
    var postComment: @Sendable (_ rowId: String, _ stage: String, _ body: String) async throws -> Void
    var decide: @Sendable (_ decision: StageDecision) async throws -> Void
    var saveDocLink: @Sendable (_ rowId: String, _ url: String) async throws -> Void
    var uploadProof: @Sendable (_ rowId: String, _ slot: Int, _ image: Data) async throws -> Void
    var startUpload: @Sendable (_ request: StageUploadRequest) async throws -> StageUploadTicket
    var finishUpload: @Sendable (_ request: StageUploadRequest, _ ticket: StageUploadTicket) async throws -> Void
    var data: @Sendable (_ path: String) async throws -> Data
    /// Final Cut: change the anchors' toss after the upload (`POST api/package-cycle/toss`).
    var saveToss: @Sendable (_ rowId: String, _ toss: String) async throws -> Void
    /// Brainstorming: empty one proof-of-contact slot (`DELETE api/brainstorming/proofs`).
    var removeProof: @Sendable (_ rowId: String, _ slot: Int) async throws -> Void
    /// Package of the Cycle certificate (a PNG) for the signed-in member.
    var certificate: @Sendable (_ rowId: String) async throws -> Data
    /// Mark a stage note handled, or open it again (`PATCH api/package-cycle/comments`). Returns the new `resolvedAt`.
    var resolveComment: @Sendable (_ id: String, _ resolved: Bool) async throws -> Date?
}

/// `PATCH api/package-cycle/comments` answer.
struct ResolvedComment: Decodable, Sendable {
    struct Comment: Decodable, Sendable { let id: String; let resolvedAt: Date? }
    let comment: Comment
}

private struct ResolveCommentBody: Encodable {
    let id: String
    let resolved: Bool
}

/// An approve / send-back decision on a group stage, with the optional feedback note.
struct StageDecision: Sendable, Hashable {
    let rowId: String
    let stage: GroupStage
    let approved: Bool
    var feedback: String = ""
    /// Initial Cut: the version being decided.
    var mediaVersionId: String?
}

/// What a student is uploading to a stage.
struct StageUploadRequest: Sendable, Hashable {
    let rowId: String
    let stage: StudentStage
    let title: String
    let fileName: String
    var rollKind: String?
    /// Final Cut: the anchors' toss (the title is the package headline).
    var toss: String?
}

extension WorkAPI {
    static func live(_ client: PortalClient) -> WorkAPI {
        WorkAPI(
            home: { try await client.get("api/app/home") },
            gates: { try await client.get("api/package-cycle/stage") },
            stage: { slug, rowId, reviewStage in
                var query = [URLQueryItem(name: "stage", value: slug)]
                if let rowId { query.append(URLQueryItem(name: "rowId", value: rowId)) }
                if let reviewStage { query.append(URLQueryItem(name: "reviewStage", value: String(reviewStage))) }
                return try await client.get("api/package-cycle/stage", query: query)
            },
            groups: { cycle in
                try await client.get("api/package-progress", query: cycle.map { [URLQueryItem(name: "cycle", value: String($0))] } ?? [])
            },
            brainstorm: { cycle in
                try await client.get("api/brainstorming", query: cycle.map { [URLQueryItem(name: "cycle", value: String($0))] } ?? [])
            },
            comments: { rowId, stage in
                try await client.get("api/package-cycle/comments", query: [
                    URLQueryItem(name: "rowId", value: rowId), URLQueryItem(name: "stage", value: stage),
                    URLQueryItem(name: "markRead", value: "1"),
                ])
            },
            postComment: { rowId, stage, body in
                try await client.post("api/package-cycle/comments", body: ["rowId": rowId, "stage": stage, "body": body])
            },
            decide: { decision in try await WorkDecisions.send(decision, client: client) },
            saveDocLink: { rowId, url in
                _ = try await client.send("PATCH", "api/brainstorming",
                                          body: try PortalJSON.encoder().encode(["kind": "doc", "rowId": rowId, "url": url]))
            },
            uploadProof: { rowId, slot, image in
                try await ProofUpload.send(rowId: rowId, slot: slot, jpeg: image, client: client)
            },
            startUpload: { request in
                try await client.post("api/package-cycle/upload", body: StageUploadBody(action: "init", request: request))
            },
            finishUpload: { request, ticket in
                try await client.post("api/package-cycle/upload",
                                      body: StageUploadBody(action: "complete", request: request, ticket: ticket))
            },
            data: { path in try await client.send("GET", path) },
            saveToss: { rowId, toss in
                try await client.post("api/package-cycle/toss", body: ["rowId": rowId, "toss": toss])
            },
            removeProof: { rowId, slot in
                try await client.delete("api/brainstorming/proofs", query: [
                    URLQueryItem(name: "rowId", value: rowId), URLQueryItem(name: "slot", value: String(slot)),
                ])
            },
            certificate: { rowId in
                try await client.send("GET", "api/package-cycle/package-of-cycle/certificate",
                                      query: [URLQueryItem(name: "rowId", value: rowId)])
            },
            resolveComment: { id, resolved in
                let answer: ResolvedComment = try await client.patch("api/package-cycle/comments",
                                                                     body: ResolveCommentBody(id: id, resolved: resolved))
                return answer.comment.resolvedAt
            }
        )
    }

    /// The live API, or fictional fixtures in the sample app (`SampleMode`; DEBUG also `-InFocusWorkStub`).
    static func resolve(_ client: PortalClient) -> WorkAPI {
        if SampleMode.isOn || UserDefaults.standard.bool(forKey: "InFocusWorkStub") { return .stub }
        return .live(client)
    }
}

/// `POST api/package-cycle/upload` bodies (init and complete).
private struct StageUploadBody: Encodable {
    let action: String
    let rowId: String
    let stage: String
    var title: String?
    var fileName: String?
    var rollKind: String?
    var toss: String?
    var mediaId: String?
    var versionId: String?

    init(action: String, request: StageUploadRequest, ticket: StageUploadTicket? = nil) {
        self.action = action
        rowId = request.rowId
        stage = request.stage.rawValue
        toss = request.toss
        if let ticket {
            mediaId = ticket.mediaId
            versionId = ticket.versionId
        } else {
            title = request.title
            fileName = request.fileName
            rollKind = request.rollKind
        }
    }
}

extension View {
    /// The Work API for this screen: live, or the sample app's fixtures.
    func workAPI(_ client: PortalClient) -> WorkAPI { .resolve(client) }
}
