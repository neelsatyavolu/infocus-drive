import SwiftUI

/// Admin and tools (all under More): the Admin dashboard (`/admin`), Managers
/// (`/managers`), the password vault (`/passwords`) and View as.
enum AdminRoute: Hashable {
    /// Admin dashboard: totals, access requests, people, producer team, system (`/admin`).
    case home
    case accessRequests
    case people
    case producerTeam
    case backups
    /// Switch the account the Portal shows (super admin; `VIEW_AS_LIMITED_ACTORS` on the Portal).
    case viewAs
    /// Manager tools (`/managers`).
    case managers
    /// Social media managers and the Instagram Post Maker (`/managers/social-media`).
    case socialMedia
    /// The password vault (`/passwords`).
    case passwords
    case vaultEntry(id: String)

    /// `/admin` (any `#view` lands on the dashboard), `/managers[/social-media]`, `/passwords`.
    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        let route: AdminRoute?
        switch path {
        case ["admin"]: route = .home
        case ["managers"]: route = .managers
        case ["managers", "social-media"]: route = .socialMedia
        case ["passwords"]: route = .passwords
        default: route = nil
        }
        return route.map { DeepLinkMatch(tab: .more, route: .admin($0)) }
    }
}

struct AdminDestination: View {
    let route: AdminRoute

    var body: some View {
        switch route {
        case .home: AdminScreen()
        case .accessRequests: AccessRequestsScreen()
        case .people: PeopleScreen()
        case .producerTeam: ProducerTeamScreen()
        case .backups: BackupsScreen()
        case .viewAs: ViewAsScreen()
        case .managers: ManagersScreen()
        case .socialMedia: SocialMediaManagersScreen()
        case .passwords: PasswordsScreen()
        case .vaultEntry(let id): VaultEntryScreen(entryId: id)
        }
    }
}
