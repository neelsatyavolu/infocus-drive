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
    struct Unread: Decodable { let unreadCount: Int }

    /// After sign-in and each time the app comes back: extension requests
    /// waiting on this person (More holds Extensions) and unread chats, so
    /// the Messages badge is right before that tab is ever opened.
    func refresh(using client: PortalClient) async {
        async let awaiting = try? client.get("api/extensions/requests/awaiting", as: Awaiting.self)
        async let unread = try? client.get("api/hub-chat/unread", as: Unread.self)
        if let awaiting = await awaiting { set(awaiting.count, for: .more) }
        if let unread = await unread { set(unread.unreadCount, for: .messages) }
    }

    func clear() {
        counts = [:]
    }
}
