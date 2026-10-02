import Foundation
import Observation

/// The Messages tab: every visible chat, polled every 5 s like the web panel.
@MainActor @Observable
final class InboxModel {
    private(set) var state: Loadable<ChatInbox> = .idle
    var query = ""
    private(set) var opening: String?
    var openError: String?

    private let service: ChatService

    init(service: ChatService) {
        self.service = service
    }

    var chats: [ChatSummary] {
        Self.filter(state.value?.chats ?? [], query: query)
    }

    nonisolated static func filter(_ chats: [ChatSummary], query: String) -> [ChatSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return chats }
        return chats.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.subtitle.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Returns the unread total for the tab badge, when it loaded.
    @discardableResult
    func load() async -> Int? {
        if state.value == nil { state = .loading }
        do {
            let inbox = try await service.inbox()
            state = .loaded(inbox)
            return inbox.unreadCount
        } catch {
            if state.value == nil { state = .failed(Loadable<ChatInbox>.message(for: error)) }
            return nil
        }
    }

    func poll(onUnread: (Int) -> Void) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: ChatLimits.inboxPoll)
            guard !Task.isCancelled else { break }
            if let unread = await load() { onUnread(unread) }
        }
    }

    /// The chat to show for a row: its id, or a new one the Portal creates for a package group.
    func chatId(for chat: ChatSummary) async -> String? {
        if let id = chat.chatId { return id }
        guard let row = chat.packageRowId else { return nil }
        return await open(.group(packageRowId: row), key: chat.id)
    }

    func open(_ target: ChatTarget, key: String) async -> String? {
        opening = key
        defer { opening = nil }
        do {
            return try await service.open(target).chat.id
        } catch {
            openError = Loadable<ChatInbox>.message(for: error)
            return nil
        }
    }
}
