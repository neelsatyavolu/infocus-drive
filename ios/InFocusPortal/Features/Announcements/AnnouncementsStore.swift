import Foundation
import Observation

/// The #announcements feed, shared by the Calendar tab (unread count) and the feed screens.
/// Slack posts have no read receipts, so "unread" means newer than the last post this person
/// saw on this iPhone (kept per account). The first load only sets that mark.
@MainActor @Observable
final class AnnouncementsStore {
    static let shared = AnnouncementsStore()

    private(set) var state: Loadable<SlackFeed> = .idle
    private(set) var lastSeen: Double = 0
    private var owner: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var posts: [SlackPost] { state.value?.items ?? [] }
    var unreadCount: Int { posts.filter { $0.sortKey > lastSeen }.count }

    func isUnread(_ post: SlackPost) -> Bool { post.sortKey > lastSeen }

    /// Each account keeps its own read mark.
    func reset(for email: String) {
        guard owner != email else { return }
        owner = email
        state = .idle
        lastSeen = defaults.double(forKey: seenKey)
    }

    /// The Calendar tab loads with its own API; the feed itself now comes from Slack,
    /// so it reads through the app's Portal client.
    func load(api _: CalendarAPI, force: Bool = false) async {
        await load(api: AnnouncementsAPI.current(AppModel.shared.client), force: force)
    }

    func load(api: AnnouncementsAPI, force: Bool = false) async {
        if !force, state.value != nil || state.isLoading { return }
        if state.value == nil { state = .loading }
        do {
            let feed = try await api.slackFeed()
            state = .loaded(feed)
            if defaults.object(forKey: seenKey) == nil { markAllSeen() }
        } catch {
            if state.value == nil { state = .failed(Loadable<SlackFeed>.message(for: error)) }
        }
    }

    func post(_ id: String) -> SlackPost? { posts.first { $0.id == id } }

    /// Opening the feed counts every post as seen.
    func markAllSeen() {
        guard let newest = posts.map(\.sortKey).max() else { return }
        if newest > lastSeen || defaults.object(forKey: seenKey) == nil {
            lastSeen = max(lastSeen, newest)
            defaults.set(lastSeen, forKey: seenKey)
        }
    }

    private var seenKey: String { "announcements.lastSeen.\(owner ?? "")" }
}
