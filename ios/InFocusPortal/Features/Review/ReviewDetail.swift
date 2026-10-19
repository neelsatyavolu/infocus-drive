import Foundation

/// `GET api/media/<id>/review[?version=]`: what the web review page renders (Portal
/// `getMediaReviewData`): the item, its versions (newest first), every version's comments
/// (oldest first), the Initial Cut package review, and what this person may do.
struct ReviewDetail: Decodable, Sendable, Hashable {
    /// An Initial Cut's approval chain, as this person sees it (`loadApprovalView`).
    struct PackageReview: Decodable, Sendable, Hashable {
        let rowId: String
        /// `APPROVED`, `ASSOCIATE_REVIEW`, `ADVISER_REVIEW`, `EXECUTIVE_REVIEW` or `DRAFT`.
        let stage: String
        let canSubmitReview: Bool
        let canApprove: Bool
        let canUnapprove: Bool?
        let canApproveAnyway: Bool?
        let awaitingRevisedInitialCut: Bool?
        let remainingExecutiveSignoffs: Int?

        /// `hasPackageDecision`: this person has a decision to make on the package.
        var hasDecision: Bool {
            canSubmitReview || canApprove || canUnapprove == true || canApproveAnyway == true
        }
    }

    struct Person: Decodable, Sendable, Hashable {
        let userId: String
        let name: String?
        let email: String?

        var label: String { name ?? email ?? "Someone" }
    }

    let mediaId: String
    let projectId: String
    let projectName: String
    let folderName: String?
    let title: String
    let workspaceRole: ReviewWorkspaceRole?
    /// Status menu for media outside a package review (`canManageWorkspaces`).
    let canUpdateApprovalStatus: Bool
    let currentUserId: String?
    let packageReview: PackageReview?
    let assignedPeople: [Person]
    /// The version the Portal selected for `?version=` (else the current one); "" when there is none.
    let currentVersionId: String
    let versions: [ReviewVersion]
    let comments: [ReviewComment]
    /// False once an Initial Cut's review is closed to this person.
    let allowComment: Bool
    let isInitialCut: Bool
    let canViewShareLinks: Bool

    var assignees: [String] { assignedPeople.map(\.label) }

    /// The newest version (the Portal sends them newest first).
    var latestVersion: ReviewVersion? { versions.max { $0.versionNumber < $1.versionNumber } }
}
