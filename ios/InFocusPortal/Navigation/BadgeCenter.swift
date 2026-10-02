import Foundation
import Observation

/// Numbers on the tab bar. Features set their own tab's count (Messages:
/// unread chats; Work: stages waiting on you); `refresh` fills the built-in ones.
///
///     @Environment(BadgeCenter.self) private var badges
///     badges.set(unread, for: .messages)
@MainActor @Observable
final class BadgeCenter {
    private(set) var counts: [AppTab: Int] = [:]

    func count(_ tab: AppTab) -> Int { counts[tab] ?? 0 }

    func set(_ count: Int, for tab: AppTab) {
        counts[tab] = max(0, count)
    }

    struct Awaiting: Decodable { let count: Int }

    /// After sign-in and each time the app comes back: extension requests
    /// waiting on this person (More holds Extensions).
    func refresh(using client: PortalClient) async {
        if let awaiting = try? await client.get("api/extensions/requests/awaiting", as: Awaiting.self) {
            set(awaiting.count, for: .more)
        }
    }

    func clear() {
        counts = [:]
    }
}
