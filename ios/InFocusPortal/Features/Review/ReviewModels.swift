import Foundation

/// This person's role in a workspace (the Portal schema's `WorkspaceRole`).
enum ReviewWorkspaceRole: String, Decodable, Sendable, Hashable {
    case ownerAdmin = "OWNER_ADMIN"
    case editor = "EDITOR"
    case reviewer = "REVIEWER"

    /// Same order as the Portal's `roleAtLeast` (`src/lib/rbac.ts`).
    var weight: Int {
        switch self {
        case .reviewer: 1
        case .editor: 2
        case .ownerAdmin: 3
        }
    }

    func atLeast(_ minimum: ReviewWorkspaceRole) -> Bool { weight >= minimum.weight }
}

/// `GET api/workspaces`: the workspaces this person can see and their role in each.
struct ReviewWorkspaceAccess: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let role: ReviewWorkspaceRole?
    let projectCount: Int?
}

/// `GET api/app/home`, just the workspaces and their projects.
struct ReviewHomeWorkspaces: Decodable, Sendable {
    let workspaces: [WorkspaceSummary]
}

/// `GET api/projects/<id>/shell`: name, workspace, folders (Portal `ProjectShellData`).
struct ReviewProjectShell: Decodable, Sendable, Hashable {
    struct WorkspaceRef: Decodable, Sendable, Hashable { let id: String; let name: String }
    struct CurrentAsset: Decodable, Sendable, Hashable {
        let id: String
        let title: String
        let folderId: String?
        let folderName: String?
    }

    let projectId: String
    let projectName: String
    let workspace: WorkspaceRef
    let folders: [ReviewFolder]
    let assetCount: Int
    let currentAsset: CurrentAsset?
    let canViewShareLinks: Bool
}

struct ReviewFolder: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let activeMediaCount: Int
}

/// `GET api/projects/<id>/media`: one page of media items (Portal `getProjectMediaPage`).
struct ReviewMediaPage: Decodable, Sendable, Hashable {
    let items: [ReviewMedia]
    let totalCount: Int
    let page: Int
    let pageSize: Int
    let totalPages: Int
}

/// A person attached to a media item (uploader, assignee, who deleted it).
struct ReviewPerson: Decodable, Sendable, Hashable {
    let id: String?
    let name: String?
    let email: String?

    var label: String { name ?? email ?? "Someone" }
}

struct ReviewMedia: Decodable, Sendable, Hashable, Identifiable {
    struct Assignment: Decodable, Sendable, Hashable { let user: ReviewPerson }

    let id: String
    let title: String
    let folderId: String?
    let currentVersionId: String?
    let deletedAt: Date?
    let updatedAt: Date?
    let versions: [ReviewVersion]
    let memberAssignments: [Assignment]?
    let deletedBy: ReviewPerson?

    /// The version the project shows: the current one, else the newest.
    var currentVersion: ReviewVersion? {
        versions.first { $0.id == currentVersionId } ?? versions.max { $0.versionNumber < $1.versionNumber }
    }

    var isDeleted: Bool { deletedAt != nil }
    var assignees: [String] { (memberAssignments ?? []).map(\.user.label) }
}

enum ReviewSourceType: String, Decodable, Sendable, Hashable {
    case video = "VIDEO"
    case image = "IMAGE"

    init(from decoder: Decoder) throws {
        self = ReviewSourceType(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .video
    }
}

enum ReviewMediaStatus: String, Decodable, Sendable, Hashable {
    case uploading = "UPLOADING"
    case processing = "PROCESSING"
    case ready = "READY"
    case failed = "FAILED"

    init(from decoder: Decoder) throws {
        self = ReviewMediaStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .processing
    }
}

enum ReviewApproval: String, Codable, Sendable, Hashable, CaseIterable {
    case inReview = "IN_REVIEW"
    case needsChanges = "NEEDS_CHANGES"
    case approved = "APPROVED"
    case aired = "AIRED"

    init(from decoder: Decoder) throws {
        self = ReviewApproval(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .inReview
    }
}

struct ReviewVersion: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let versionNumber: Int
    let sourceType: ReviewSourceType
    let status: ReviewMediaStatus
    let approvalStatus: ReviewApproval
    let airedAt: Date?
    let durationSeconds: Double?
    let createdAt: Date
    let createdBy: ReviewPerson?
    let commentCount: Int

    var isImage: Bool { sourceType == .image }
    var isReady: Bool { status == .ready }

    private enum CodingKeys: String, CodingKey {
        case id, versionNumber, sourceType, status, approvalStatus, airedAt, durationSeconds, createdAt, createdBy
        case count = "_count"
    }

    private struct Count: Decodable { let comments: Int? }

    init(id: String, versionNumber: Int, sourceType: ReviewSourceType, status: ReviewMediaStatus, approvalStatus: ReviewApproval,
         airedAt: Date? = nil, durationSeconds: Double? = nil, createdAt: Date, createdBy: ReviewPerson? = nil, commentCount: Int = 0) {
        self.id = id
        self.versionNumber = versionNumber
        self.sourceType = sourceType
        self.status = status
        self.approvalStatus = approvalStatus
        self.airedAt = airedAt
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.commentCount = commentCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        versionNumber = try container.decode(Int.self, forKey: .versionNumber)
        sourceType = try container.decodeIfPresent(ReviewSourceType.self, forKey: .sourceType) ?? .video
        status = try container.decode(ReviewMediaStatus.self, forKey: .status)
        approvalStatus = try container.decodeIfPresent(ReviewApproval.self, forKey: .approvalStatus) ?? .inReview
        airedAt = try container.decodeIfPresent(Date.self, forKey: .airedAt)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        createdBy = try container.decodeIfPresent(ReviewPerson.self, forKey: .createdBy)
        commentCount = try container.decodeIfPresent(Count.self, forKey: .count)?.comments ?? 0
    }
}

/// `GET api/media/<id>/playback-token`: a signed URL for one version.
struct ReviewPlaybackToken: Decodable, Sendable, Hashable {
    let playbackUrl: URL
    let provider: String?
}

/// A review comment as `POST api/comments` and the replies route return it (a `ReviewComment` row).
struct ReviewComment: Decodable, Sendable, Hashable, Identifiable {
    enum Target: String, Codable, Sendable, Hashable {
        case timecode = "TIMECODE"
        case framePin = "FRAME_PIN"
        case general = "GENERAL"
    }

    let id: String
    let mediaVersionId: String
    let authorId: String?
    let parentCommentId: String?
    let targetType: Target
    let timeSeconds: Double
    let xPct: Double?
    let yPct: Double?
    var body: String
    let createdAt: Date
    var resolvedAt: Date?
    /// Not on the Portal's row; filled in for comments the app shows by name.
    var authorName: String?

    var isResolved: Bool { resolvedAt != nil }
    var isReply: Bool { parentCommentId != nil }
}

/// A guest review link (a `GuestLink` row): anyone with it can view or comment without an account.
struct ReviewGuestLink: Decodable, Sendable, Hashable, Identifiable {
    enum Permission: String, Codable, Sendable, Hashable, CaseIterable {
        case view = "VIEW"
        case comment = "COMMENT"
    }

    let id: String
    let token: String
    let permission: Permission
    let expiresAt: Date?
    let revokedAt: Date?
    let createdAt: Date

    func isActive(now: Date = Date()) -> Bool {
        revokedAt == nil && (expiresAt.map { $0 > now } ?? true)
    }
}

/// `POST api/media/init-upload`: the new item, its first version, and where the file goes.
struct ReviewUploadTicket: Decodable, Sendable, Hashable {
    struct Ref: Decodable, Sendable, Hashable { let id: String }
    /// InFocus Drive (`NAS`) or legacy Bunny, which the app can't upload to.
    struct Target: Decodable, Sendable, Hashable {
        let provider: String?
        let uploadUrl: URL?
        let path: String?
        let token: String?

        var drive: DriveUploadSession? {
            guard provider == "NAS", let uploadUrl else { return nil }
            return DriveUploadSession(provider: provider, uploadUrl: uploadUrl, path: path, token: token)
        }
    }

    let media: Ref
    let version: Ref
    let upload: Target
}

/// `POST api/projects`: the new project.
struct ReviewCreatedProject: Decodable, Sendable, Hashable {
    let id: String
    let name: String
}
