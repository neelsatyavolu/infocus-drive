import Foundation
import SwiftUI

/// Every Portal call the Work area makes, in one place. Screens build it from
/// the environment's client (`workAPI(client)`); DEBUG screenshots swap in
/// fixtures (`-InFocusWorkStub`), so no screen ever needs a live Portal to render.
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
            data: { path in try await client.send("GET", path) }
        )
    }

    /// The live API, or fixtures for DEBUG screenshots (`-InFocusWorkStub`).
    static func resolve(_ client: PortalClient) -> WorkAPI {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "InFocusWorkStub") { return .stub }
        #endif
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
    /// The Work API for this screen: live, or DEBUG fixtures.
    func workAPI(_ client: PortalClient) -> WorkAPI { .resolve(client) }
}
