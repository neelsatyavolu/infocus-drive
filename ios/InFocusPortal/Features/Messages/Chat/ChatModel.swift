import Foundation
import Observation

/// A message typed here that the Portal hasn't confirmed yet (optimistic send).
struct PendingMessage: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable { case sending, failed(String) }

    let id: String
    let body: String
    let createdAt: Date
    var status: Status = .sending
}

/// One row of the conversation: a day heading, a message, or a pending message.
enum ChatRow: Identifiable, Hashable {
    case day(id: String, title: String)
    case message(ChatMessage, isMine: Bool, showsAuthor: Bool)
    case pending(PendingMessage)

    var id: String {
        switch self {
        case .day(let id, _): "day-\(id)"
        case .message(let message, _, _): message.id
        case .pending(let pending): "pending-\(pending.id)"
        }
    }

    /// Day headings, and author names in group chats when the speaker changes.
    static func build(messages: [ChatMessage], pending: [PendingMessage], meId: String?, isGroup: Bool,
                      now: Date = Date()) -> [ChatRow] {
        var rows: [ChatRow] = []
        var previous: ChatMessage?
        for message in messages {
            let newDay = previous.map { !FeatureDates.sameDay($0.createdAt, message.createdAt) } ?? true
            if newDay {
                rows.append(.day(id: message.id, title: FeatureDates.dayHeading(message.createdAt, now: now)))
            }
            let isMine = message.authorId == meId
            let showsAuthor = isGroup && !isMine && (newDay || previous?.authorId != message.authorId)
            rows.append(.message(message, isMine: isMine, showsAuthor: showsAuthor))
            previous = message
        }
        if let first = pending.first, previous.map({ !FeatureDates.sameDay($0.createdAt, first.createdAt) }) ?? true {
            rows.append(.day(id: "pending", title: FeatureDates.dayHeading(first.createdAt, now: now)))
        }
        rows += pending.map(ChatRow.pending)
        return rows
    }
}

/// A conversation: loads, polls every 4 s like the web panel, and sends optimistically.
@MainActor @Observable
final class ChatModel {
    private(set) var info: Loadable<ChatInfo> = .idle
    private(set) var messages: [ChatMessage] = []
    private(set) var pending: [PendingMessage] = []
    private(set) var meId: String?
    var draft = ""

    private let service: ChatService
    private var chatId: String?
    private let target: ChatTarget?

    init(chatId: String, service: ChatService) {
        self.chatId = chatId
        self.target = nil
        self.service = service
    }

    init(target: ChatTarget, service: ChatService) {
        self.target = target
        self.service = service
    }

    var rows: [ChatRow] {
        ChatRow.build(messages: messages, pending: pending, meId: meId, isGroup: info.value?.kind == .group)
    }

    var canSend: Bool {
        chatId != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load() async {
        if info.value == nil { info = .loading }
        do {
            let thread: ChatThread
            if let chatId {
                thread = try await service.thread(chatId)
            } else if let target {
                thread = try await service.open(target)
            } else {
                return
            }
            apply(thread)
        } catch {
            // Keep showing what we have; only a first load turns into an error screen.
            if info.value == nil { info = .failed(Loadable<ChatInfo>.message(for: error)) }
        }
    }

    /// Runs until the view goes away (`.task` cancels it).
    func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: ChatLimits.threadPoll)
            guard !Task.isCancelled, chatId != nil else { continue }
            await load()
        }
    }

    func send() async {
        let body = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatLimits.bodyMax))
        guard !body.isEmpty else { return }
        draft = ""
        let message = PendingMessage(id: UUID().uuidString, body: body, createdAt: Date())
        pending.append(message)
        await deliver(message)
    }

    func retry(_ message: PendingMessage) async {
        guard let index = pending.firstIndex(where: { $0.id == message.id }) else { return }
        pending[index].status = .sending
        await deliver(pending[index])
    }

    func discard(_ message: PendingMessage) {
        pending.removeAll { $0.id == message.id }
    }

    private func deliver(_ message: PendingMessage) async {
        guard let chatId else { return }
        do {
            let sent = try await service.send(chatId, message.body)
            pending.removeAll { $0.id == message.id }
            if !messages.contains(where: { $0.id == sent.id }) { messages.append(sent) }
        } catch {
            if let index = pending.firstIndex(where: { $0.id == message.id }) {
                pending[index].status = .failed(Loadable<ChatMessage>.message(for: error))
            }
        }
    }

    private func apply(_ thread: ChatThread) {
        chatId = thread.chat.id
        meId = thread.me.id
        info = .loaded(thread.chat)
        messages = Self.merge(server: thread.messages, sent: messages)
    }

    /// The server's latest 200, plus anything just sent that a poll raced past (never twice).
    nonisolated static func merge(server: [ChatMessage], sent: [ChatMessage]) -> [ChatMessage] {
        let known = Set(server.map(\.id))
        let newest = server.last?.createdAt ?? .distantPast
        let extra = sent.filter { !known.contains($0.id) && $0.createdAt > newest }
        return server + extra
    }
}
