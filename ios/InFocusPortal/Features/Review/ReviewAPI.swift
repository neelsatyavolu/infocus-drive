import Foundation

/// Which page of a project's media to load (the web project page's `scope`, `folderId`, `filter`, `sort`, `page`).
struct ReviewMediaQuery: Sendable, Hashable {
    enum Scope: String, Sendable, CaseIterable { case active, deleted }
    enum Filter: String, Sendable, CaseIterable { case all, ready, inProgress = "in-progress", failed }
    enum Sort: String, Sendable, CaseIterable { case recent, name, status }

    var scope: Scope = .active
    /// A folder id; nil is the project's top level. It's sent as "root": the Portal reads "all"
    /// as every folder's deleted items, which isn't what the Top level chip says.
    var folderId: String?
    var filter: Filter = .all
    var sort: Sort = .recent
    var page = 1

    var items: [URLQueryItem] {
        [URLQueryItem(name: "scope", value: scope.rawValue),
         URLQueryItem(name: "folderId", value: folderId ?? "root"),
         URLQueryItem(name: "filter", value: filter.rawValue),
         URLQueryItem(name: "sort", value: sort.rawValue),
         URLQueryItem(name: "page", value: String(page))]
    }
}

/// A new comment (Portal `commentPayloadSchema`).
struct NewReviewComment: Encodable, Sendable, Hashable {
    let mediaVersionId: String
    let targetType: ReviewComment.Target
    var timeSeconds: Double?
    var frameNumber: Int?
    var xPct: Double?
    var yPct: Double?
    let body: String
}

/// A guest link to create (`POST api/guest-links`).
struct NewGuestLink: Encodable, Sendable, Hashable {
    let projectId: String
    let permission: ReviewGuestLink.Permission
    var passcode: String?
    var expiresAt: Date?
}

/// A new video for a project (`POST api/media/init-upload`).
struct ReviewUploadRequest: Encodable, Sendable, Hashable {
    let projectId: String
    let title: String
    let fileName: String
    var folderId: String?
}

/// Every Portal call the review screens make. Screens build it from the
/// environment's client (`ReviewAPI.resolve(client)`); the sample app swaps in
/// fixtures (`SampleMode`), so nothing reaches the Portal from it.
struct ReviewAPI: Sendable {
    var workspaces: @Sendable () async throws -> [WorkspaceSummary]
    var roles: @Sendable () async throws -> [ReviewWorkspaceAccess]
    var shell: @Sendable (_ projectId: String, _ mediaId: String?) async throws -> ReviewProjectShell
    var media: @Sendable (_ projectId: String, _ query: ReviewMediaQuery) async throws -> ReviewMediaPage
    var playback: @Sendable (_ mediaId: String, _ versionId: String) async throws -> ReviewPlaybackToken
    var image: @Sendable (_ mediaId: String, _ versionId: String) async throws -> Data
    /// One item's review: versions, every version's comments, package review and permissions.
    /// `version` is a version id (or number); nil or unknown picks the current version.
    var review: @Sendable (_ mediaId: String, _ version: String?) async throws -> ReviewDetail
    /// A fresh poster URL for a version (video posters are signed and expire).
    var poster: @Sendable (_ mediaId: String, _ versionId: String) async throws -> String?
    var comment: @Sendable (_ comment: NewReviewComment) async throws -> ReviewComment
    var reply: @Sendable (_ parentId: String, _ body: String) async throws -> ReviewComment
    var setResolved: @Sendable (_ commentId: String, _ resolved: Bool) async throws -> Void
    var editComment: @Sendable (_ commentId: String, _ body: String) async throws -> Void
    var deleteComment: @Sendable (_ commentId: String) async throws -> Void
    var setApproval: @Sendable (_ mediaId: String, _ versionId: String, _ status: ReviewApproval, _ airedAt: Date?) async throws -> Void
    var rename: @Sendable (_ mediaId: String, _ title: String) async throws -> Void
    var deleteMedia: @Sendable (_ mediaId: String) async throws -> Void
    var restoreMedia: @Sendable (_ mediaId: String) async throws -> Void
    var deleteForever: @Sendable (_ mediaId: String) async throws -> Void
    var createFolder: @Sendable (_ projectId: String, _ name: String) async throws -> Void
    var createProject: @Sendable (_ workspaceId: String, _ name: String) async throws -> ReviewCreatedProject
    var deleteProject: @Sendable (_ projectId: String) async throws -> Void
    var guestLinks: @Sendable (_ projectId: String) async throws -> [ReviewGuestLink]
    var createGuestLink: @Sendable (_ link: NewGuestLink) async throws -> Void
    var revokeGuestLink: @Sendable (_ id: String) async throws -> Void
    var startUpload: @Sendable (_ request: ReviewUploadRequest) async throws -> ReviewUploadTicket
    var finishUpload: @Sendable (_ mediaId: String, _ versionId: String) async throws -> Void
    var uploadImage: @Sendable (_ projectId: String, _ folderId: String?, _ title: String, _ jpeg: Data) async throws -> Void
}

extension ReviewAPI {
    static func live(_ client: PortalClient) -> ReviewAPI {
        ReviewAPI(
            workspaces: { try await client.get("api/app/home", as: ReviewHomeWorkspaces.self).workspaces },
            roles: { try await client.get("api/workspaces") },
            shell: { projectId, mediaId in
                try await client.get("api/projects/\(projectId)/shell",
                                     query: mediaId.map { [URLQueryItem(name: "mediaId", value: $0)] } ?? [])
            },
            media: { projectId, query in try await client.get("api/projects/\(projectId)/media", query: query.items) },
            playback: { mediaId, versionId in
                try await client.get("api/media/\(mediaId)/playback-token",
                                     query: [URLQueryItem(name: "mediaVersionId", value: versionId)])
            },
            image: { mediaId, versionId in try await client.send("GET", "api/media/\(mediaId)/versions/\(versionId)/image") },
            review: { mediaId, version in
                try await client.get("api/media/\(mediaId)/review",
                                     query: version.map { [URLQueryItem(name: "version", value: $0)] } ?? [])
            },
            poster: { mediaId, versionId in
                try await client.get("api/media/\(mediaId)/versions/\(versionId)/poster", as: ReviewPoster.self).thumbnailUrl
            },
            comment: { comment in try await client.post("api/comments", body: comment) },
            reply: { parentId, body in try await client.post("api/comments/\(parentId)/replies", body: ["body": body]) },
            setResolved: { id, resolved in
                let _: PortalJSON.Empty = try await client.patch("api/comments/\(id)", body: ["resolved": resolved])
            },
            editComment: { id, body in
                let _: PortalJSON.Empty = try await client.patch("api/comments/\(id)", body: ["body": body])
            },
            deleteComment: { id in try await client.delete("api/comments/\(id)") },
            setApproval: { mediaId, versionId, status, airedAt in
                let _: PortalJSON.Empty = try await client.patch("api/media/\(mediaId)/approval-status",
                                                                  body: ApprovalBody(mediaVersionId: versionId, status: status,
                                                                                     airedAt: status == .aired ? airedAt : nil))
            },
            rename: { mediaId, title in
                let _: PortalJSON.Empty = try await client.patch("api/media/\(mediaId)", body: ["title": title])
            },
            deleteMedia: { mediaId in try await client.delete("api/media/\(mediaId)") },
            restoreMedia: { mediaId in try await client.post("api/media/\(mediaId)/restore", body: PortalJSON.EmptyBody()) },
            deleteForever: { mediaId in try await client.delete("api/media/\(mediaId)/permanent") },
            createFolder: { projectId, name in try await client.post("api/projects/\(projectId)/folders", body: ["name": name]) },
            createProject: { workspaceId, name in
                try await client.post("api/projects", body: ["workspaceId": workspaceId, "name": name])
            },
            deleteProject: { projectId in try await client.delete("api/projects/\(projectId)") },
            guestLinks: { projectId in try await client.get("api/projects/\(projectId)/guest-links") },
            createGuestLink: { link in try await client.post("api/guest-links", body: link) },
            revokeGuestLink: { id in try await client.post("api/guest-links/\(id)/revoke", body: PortalJSON.EmptyBody()) },
            startUpload: { request in try await client.post("api/media/init-upload", body: request) },
            finishUpload: { mediaId, versionId in
                try await client.post("api/media/\(mediaId)/versions/\(versionId)/complete-nas-upload", body: PortalJSON.EmptyBody())
            },
            uploadImage: { projectId, folderId, title, jpeg in
                try await ReviewImageUpload.send(projectId: projectId, folderId: folderId, title: title, jpeg: jpeg, client: client)
            }
        )
    }

    /// The live API, or fictional fixtures in the sample app (`SampleMode`).
    static func resolve(_ client: PortalClient) -> ReviewAPI {
        SampleMode.isOn ? .stub : .live(client)
    }
}

/// `GET api/media/<id>/versions/<versionId>/poster`.
private struct ReviewPoster: Decodable {
    let thumbnailUrl: String?
}

/// `PATCH api/media/<id>/approval-status` (`airedAt` only with AIRED).
private struct ApprovalBody: Encodable {
    let mediaVersionId: String
    let status: ReviewApproval
    let airedAt: Date?
}

/// `POST api/media/init-image-upload`: a multipart form with the image itself (10 MB at most).
enum ReviewImageUpload {
    static let maxBytes = 10 * 1024 * 1024

    static func body(projectId: String, folderId: String?, title: String, jpeg: Data, boundary: String) -> Data {
        var fields = ["projectId": projectId, "title": title]
        if let folderId { fields["folderId"] = folderId }
        var body = Multipart.fields(fields, boundary: boundary, closing: false)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    static func send(projectId: String, folderId: String?, title: String, jpeg: Data, client: PortalClient) async throws {
        guard jpeg.count <= maxBytes else {
            throw PortalError.server(status: 413, message: "Images must be 10 MB or smaller.")
        }
        let boundary = "InFocus-\(UUID().uuidString)"
        let request = await client.request("POST", "api/media/init-image-upload",
                                           body: body(projectId: projectId, folderId: folderId, title: title, jpeg: jpeg, boundary: boundary),
                                           contentType: "multipart/form-data; boundary=\(boundary)")
        _ = try await client.perform(request)
    }
}
