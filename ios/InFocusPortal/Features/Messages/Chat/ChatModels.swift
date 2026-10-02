import Foundation

/// Portal Messages (`src/server/hub-chat.ts`): package group chats and direct messages.

struct ChatPerson: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

enum ChatKind: String, Decodable, Sendable {
    case group = "GROUP"
    case direct = "DIRECT"
}

/// `GET api/hub-chat`: every chat this person can see, newest first.
struct ChatInbox: Decodable, Sendable {
    let me: ChatPerson
    let canStartDirect: Bool
    let unreadCount: Int
    let chats: [ChatSummary]
    /// People they can start a direct message with (producers only).
    let members: [ChatPerson]
}

struct ChatSummary: Decodable, Hashable, Identifiable, Sendable {
    /// Nil for a package group chat nobody has opened yet (`POST api/hub-chat` creates it).
    let chatId: String?
    let kind: ChatKind
    let title: String
    let subtitle: String
    let preview: String?
    let updatedAt: Date?
    let unreadCount: Int
    let packageRowId: String?
    let peer: ChatPerson?

    var id: String { chatId ?? "package-\(packageRowId ?? title)" }

    enum CodingKeys: String, CodingKey {
        case chatId = "id", kind, title, subtitle, preview, updatedAt, unreadCount, packageRowId, peer
    }
}

/// `GET api/hub-chat/<id>` and `POST api/hub-chat`: one chat and its latest 200 messages.
struct ChatThread: Decodable, Sendable {
    let me: ChatPerson
    let chat: ChatInfo
    let messages: [ChatMessage]
}

struct ChatInfo: Decodable, Hashable, Sendable {
    let id: String
    let kind: ChatKind
    let title: String
    let subtitle: String
    let packageRowId: String?
    let peer: ChatPerson?
}

struct ChatMessage: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let body: String
    let createdAt: Date
    let authorId: String
    let author: ChatPerson
}

/// `POST api/hub-chat/<id>`.
struct SentChatMessage: Decodable, Sendable {
    let message: ChatMessage
}

/// What `POST api/hub-chat` opens.
enum ChatTarget: Hashable, Sendable {
    case group(packageRowId: String)
    case direct(userId: String)

    var body: OpenChatBody {
        switch self {
        case .group(let id): OpenChatBody(kind: "GROUP", packageRowId: id, userId: nil)
        case .direct(let id): OpenChatBody(kind: "DIRECT", packageRowId: nil, userId: id)
        }
    }
}

struct OpenChatBody: Encodable, Sendable {
    let kind: String
    let packageRowId: String?
    let userId: String?
}

enum ChatLimits {
    /// `HUB_CHAT_BODY_MAX`: the Portal trims longer messages.
    static let bodyMax = 2000
    /// The web panel's polling cadence (`components/hub-messages.tsx`).
    static let inboxPoll: UInt64 = 5_000_000_000
    static let threadPoll: UInt64 = 4_000_000_000
}
