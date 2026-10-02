import Foundation
import Observation

/// The class announcements feed, shared by the Calendar tab (unread count) and the feed screens.
/// Likes and comments update in place; a failed action rolls back and says why.
@MainActor @Observable
final class AnnouncementsStore {
    static let shared = AnnouncementsStore()

    private(set) var state: Loadable<[ClassAnnouncement]> = .idle
    var actionError: String?
    private var owner: String?

    var unreadCount: Int { state.value?.filter(\.unread).count ?? 0 }

    func reset(for email: String) {
        guard owner != email else { return }
        owner = email
        state = .idle
    }

    func load(api: CalendarAPI, force: Bool = false) async {
        if !force, state.value != nil || state.isLoading { return }
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.announcements())
        } catch {
            if state.value == nil { state = .failed(Loadable<[ClassAnnouncement]>.message(for: error)) }
        }
    }

    func announcement(_ id: String) -> ClassAnnouncement? { state.value?.first { $0.id == id } }

    func toggleLike(_ id: String, api: CalendarAPI) async {
        guard let current = announcement(id) else { return }
        let liked = !current.likedByMe
        update(id) { $0.likedByMe = liked; $0.likeCount += liked ? 1 : -1 }
        do {
            let result = try await api.setLiked(id, liked)
            update(id) { $0.likedByMe = result.likedByMe; $0.likeCount = result.likeCount }
        } catch {
            update(id) { $0.likedByMe = current.likedByMe; $0.likeCount = current.likeCount }
            actionError = Loadable<Bool>.message(for: error)
        }
    }

    func markRead(_ id: String, api: CalendarAPI) async {
        guard announcement(id)?.unread == true else { return }
        update(id) { $0.unread = false }
        try? await api.markRead(id)
    }

    /// Returns true when the comment was posted.
    func addComment(_ body: String, to id: String, api: CalendarAPI) async -> Bool {
        do {
            let comment = try await api.comment(id, body)
            update(id) { $0.comments.append(comment); $0.unread = false }
            return true
        } catch {
            actionError = Loadable<Bool>.message(for: error)
            return false
        }
    }

    /// Producers: post to the whole class, then reload the feed.
    func post(_ content: String, api: CalendarAPI) async -> Bool {
        do {
            try await api.post(content)
            await load(api: api, force: true)
            return true
        } catch {
            actionError = Loadable<Bool>.message(for: error)
            return false
        }
    }

    private func update(_ id: String, _ change: (inout ClassAnnouncement) -> Void) {
        guard var list = state.value, let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        state = .loaded(list)
    }
}
