import Foundation

/// Fictional chats for `-InFocusStubSession` screenshots. Never real people.
extension ChatService {
    static let stub: ChatService = {
        let me = ChatPerson(id: "me", name: "Abby")
        let otto = ChatPerson(id: "otto", name: "Otto")
        let sage = ChatPerson(id: "sage", name: "Sage")
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        let group = ChatInfo(id: "chat-group", kind: .group, title: "Abby, Otto & Sage",
                             subtitle: "Club Fair · Cycle 2", packageRowId: "row-1", peer: nil)
        let messages = [
            ChatMessage(id: "m1", body: "Interview with the club fair organizers is set for Thursday at lunch.",
                        createdAt: ago(60 * 26), authorId: "otto", author: otto),
            ChatMessage(id: "m2", body: "Nice! I'll bring the shotgun mic and the small tripod.",
                        createdAt: ago(60 * 25), authorId: "me", author: me),
            ChatMessage(id: "m3", body: "Can someone grab B-roll of the booths during setup?",
                        createdAt: ago(42), authorId: "sage", author: sage),
            ChatMessage(id: "m4", body: "On it, I'm free 4th period.", createdAt: ago(38), authorId: "me", author: me),
            ChatMessage(id: "m5", body: "Perfect. Initial cut due Monday 🎬", createdAt: ago(5), authorId: "otto", author: otto),
        ]
        let inbox = ChatInbox(
            me: me, canStartDirect: true, unreadCount: 3,
            chats: [
                ChatSummary(chatId: "chat-group", kind: .group, title: group.title, subtitle: group.subtitle,
                            preview: messages.last?.body, updatedAt: ago(5), unreadCount: 2, packageRowId: "row-1", peer: nil),
                ChatSummary(chatId: "chat-sage", kind: .direct, title: "Sage", subtitle: "Direct",
                            preview: "Thanks for covering the game!", updatedAt: ago(60 * 20), unreadCount: 1,
                            packageRowId: nil, peer: sage),
                ChatSummary(chatId: nil, kind: .group, title: "Abby & Otto", subtitle: "Gas Prices · Cycle 1",
                            preview: nil, updatedAt: nil, unreadCount: 0, packageRowId: "row-2", peer: nil),
            ],
            members: [otto, sage]
        )
        let thread = ChatThread(me: me, chat: group, messages: messages)
        return ChatService(
            inbox: { await FeatureStub.delay(); return inbox },
            thread: { _ in await FeatureStub.delay(); return thread },
            open: { _ in await FeatureStub.delay(); return thread },
            send: { _, body in
                ChatMessage(id: UUID().uuidString, body: body, createdAt: Date(), authorId: "me", author: me)
            }
        )
    }()
}
