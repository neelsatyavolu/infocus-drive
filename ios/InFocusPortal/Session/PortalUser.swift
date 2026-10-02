import Foundation

/// The Portal's `PlatformRole` (CLAUDE.md Terminology). No role is a student.
enum PlatformRole: String, Codable, Sendable, CaseIterable {
    case associateProducer = "ASSOCIATE_PRODUCER"
    case executiveProducer = "EXECUTIVE_PRODUCER"
    case adviser = "ADVISER"
    case superAdmin = "SUPER_ADMIN"

    /// Same weights as the Portal (`platformRoleWeight`): adviser ranks with EPs.
    var weight: Int {
        switch self {
        case .associateProducer: 1
        case .executiveProducer, .adviser: 2
        case .superAdmin: 3
        }
    }

    var label: String {
        switch self {
        case .associateProducer: "Associate producer"
        case .executiveProducer: "Executive producer"
        case .adviser: "Adviser"
        case .superAdmin: "Super admin"
        }
    }
}

/// Who is signed in, and what the Portal lets them do. Mirrors the web
/// sidebar's rules (components/app-shell.tsx) so the tabs match the website.
struct PortalUser: Equatable, Sendable {
    var email: String
    var name: String
    var nickname: String?
    var role: PlatformRole?
    /// On a Package Cycle roster this cycle (students; associates can be too).
    var onStudentPackage: Bool
    /// The Apple App Review account: only its sample workspace (Home) and Settings.
    /// The Portal answers 403 for everything else.
    var sampleOnly = false

    /// The on-screen name: nickname, else the first name.
    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    func has(_ minimum: PlatformRole) -> Bool {
        guard let role else { return false }
        return role.weight >= minimum.weight
    }

    /// Associate producer and up: Groups, Members, Package Cycle, Publishing Queue, The Show.
    var isProducer: Bool { has(.associateProducer) }
    var isAssociate: Bool { role == .associateProducer }
    /// Stage 3 executive: EPs and the super admin, never the adviser (`isExecutiveProducer()`).
    var isExecutive: Bool { role == .executiveProducer || role == .superAdmin }
    var isAdviser: Bool { role == .adviser }
    /// Platform admin powers: super admin and adviser (`isPlatformSuperAdmin`).
    var isSuperAdmin: Bool { role == .superAdmin || role == .adviser }

    /// Student cycle work (brainstorming → final cut): students, and associates on a package.
    var doesStudentWork: Bool { !isProducer || (isAssociate && onStudentPackage) }
    /// The student gradebook; EPs, the adviser and the super admin don't have one.
    var seesStudentGrades: Bool { !has(.executiveProducer) }
    var canManageGrades: Bool { has(.executiveProducer) }
    var canManageAccounts: Bool { has(.executiveProducer) }

    var roleLabel: String { sampleOnly ? "Sample account" : role?.label ?? "Student" }
}

extension PortalUser {
    /// DEBUG launch argument `-InFocusStubSession <student|associate|producer|executive|admin|sample>`
    /// shows the shell without a Portal (screenshots, previews). Fictional people only.
    static func stub(_ kind: String) -> PortalUser {
        switch kind {
        case "associate":
            PortalUser(email: "otto@example.edu", name: "Otto Example", role: .associateProducer, onStudentPackage: true)
        case "producer", "executive":
            PortalUser(email: "sage@example.edu", name: "Sage Example", role: .executiveProducer, onStudentPackage: false)
        case "admin":
            PortalUser(email: "superadmin@example.edu", name: "Admin Example", role: .superAdmin, onStudentPackage: false)
        case "sample":
            PortalUser(email: "review@example.edu", name: "App Review", role: nil, onStudentPackage: false, sampleOnly: true)
        default:
            PortalUser(email: "abby@example.edu", name: "Abby Example", role: nil, onStudentPackage: true)
        }
    }
}
