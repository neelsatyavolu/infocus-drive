import Foundation
import Observation

/// The signed-in person and their role, loaded once after sign-in (and again
/// on pull-to-refresh in Settings). Tabs and More read it to adapt.
///
///     @Environment(SessionStore.self) private var session
///     if session.user?.isProducer == true { … }
@MainActor @Observable
final class SessionStore {
    private(set) var state: Loadable<PortalUser> = .idle

    var user: PortalUser? { state.value }

    // The Portal's answers (only the fields the app shell uses).
    struct PlatformMe: Decodable { let email: String?; let role: String? }
    struct Profile: Decodable { let email: String?; let name: String?; let nickname: String?; let sampleOnly: Bool? }
    struct StageNav: Decodable { let hasRow: Bool? }

    /// `GET api/profile` (name; `sampleOnly` for the App Review account, which
    /// may call nothing else), then `GET api/platform/me` (role) and
    /// `GET api/package-cycle/stage` for anyone who might do student work.
    func load(using client: PortalClient) async {
        if state.value == nil { state = .loading }
        do {
            let person = try await client.get("api/profile", as: Profile.self)
            if person.sampleOnly == true {
                state = .loaded(PortalUser(email: person.email ?? "", name: person.name ?? "Sample account",
                                           nickname: person.nickname, role: nil, onStudentPackage: false,
                                           sampleOnly: true))
                return
            }
            let platform = try await client.get("api/platform/me", as: PlatformMe.self)
            var user = PortalUser(email: person.email ?? platform.email ?? "",
                                  name: person.name ?? person.email ?? "",
                                  nickname: person.nickname,
                                  role: platform.role.flatMap(PlatformRole.init(rawValue:)),
                                  onStudentPackage: false)
            if !user.isProducer || user.isAssociate {
                let stage = try? await client.get("api/package-cycle/stage", as: StageNav.self)
                user.onStudentPackage = stage?.hasRow ?? false
            }
            state = .loaded(user)
        } catch {
            if case .loaded = state { return } // keep showing who we knew
            state = .failed(Loadable<PortalUser>.message(for: error))
        }
    }

    /// DEBUG stub session (see `PortalUser.stub`).
    func useStub(_ user: PortalUser) {
        state = .loaded(user)
    }

    func clear() {
        state = .idle
    }
}
