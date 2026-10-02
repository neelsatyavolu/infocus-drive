import XCTest
@testable import InFocusPortal

/// Messages: decoding the Portal's hub-chat JSON, building rows, optimistic sends, deep links.
final class MessagesChatTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
    }

    private func message(_ id: String, _ author: String, _ iso: String) -> ChatMessage {
        ChatMessage(id: id, body: "Hi \(id)", createdAt: ISO8601DateFormatter().date(from: iso)!,
                    authorId: author, author: ChatPerson(id: author, name: author.capitalized))
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    func testDecodesInboxIncludingUnopenedGroupChats() throws {
        let inbox = try decode(ChatInbox.self, """
        {"data":{"me":{"id":"u1","name":"Abby"},"canStartDirect":false,"unreadCount":3,
         "chats":[
          {"id":null,"kind":"GROUP","title":"Abby, Otto & Sage","subtitle":"Club Fair · Cycle 2","preview":null,
           "updatedAt":null,"unreadCount":0,"packageRowId":"row-1","cycleNumber":2},
          {"id":"c2","kind":"DIRECT","title":"Sage","subtitle":"Direct","preview":"See you there",
           "updatedAt":"2026-10-02T19:32:36.224Z","unreadCount":3,"peer":{"id":"u3","name":"Sage"}}],
         "members":[]}}
        """)
        XCTAssertEqual(inbox.unreadCount, 3)
        XCTAssertNil(inbox.chats[0].chatId)
        XCTAssertEqual(inbox.chats[0].id, "package-row-1")
        XCTAssertEqual(inbox.chats[1].id, "c2")
        XCTAssertEqual(inbox.chats[1].kind, .direct)
        XCTAssertEqual(inbox.chats[1].peer?.name, "Sage")
    }

    func testRowsAddDayHeadingsAndGroupAuthorsOnlyWhenTheSpeakerChanges() {
        let now = ISO8601DateFormatter().date(from: "2026-10-02T20:00:00Z")!
        let messages = [
            message("1", "otto", "2026-10-01T18:00:00Z"),
            message("2", "otto", "2026-10-01T18:01:00Z"),
            message("3", "me", "2026-10-01T18:02:00Z"),
            message("4", "sage", "2026-10-02T17:00:00Z"),
        ]
        let rows = ChatRow.build(messages: messages, pending: [], meId: "me", isGroup: true, now: now)
        let summary = rows.map { row -> String in
            switch row {
            case .day(_, let title): "day:\(title)"
            case .message(let m, let mine, let author): "\(m.id):\(mine ? "mine" : "theirs"):\(author ? "name" : "-")"
            case .pending: "pending"
            }
        }
        XCTAssertEqual(summary, ["day:Yesterday", "1:theirs:name", "2:theirs:-", "3:mine:-", "day:Today", "4:theirs:name"])

        let direct = ChatRow.build(messages: messages, pending: [], meId: "me", isGroup: false, now: now)
        XCTAssertFalse(direct.contains { if case .message(_, _, true) = $0 { true } else { false } })
    }

    func testMergeKeepsAJustSentMessageAPollRacedPastButNeverTwice() {
        let server = [message("1", "otto", "2026-10-02T18:00:00Z")]
        let sent = message("2", "me", "2026-10-02T18:05:00Z")
        XCTAssertEqual(ChatModel.merge(server: server, sent: [sent]).map(\.id), ["1", "2"])
        XCTAssertEqual(ChatModel.merge(server: server + [sent], sent: [sent]).map(\.id), ["1", "2"])
        let old = message("0", "me", "2026-10-02T17:00:00Z")
        XCTAssertEqual(ChatModel.merge(server: server, sent: [old]).map(\.id), ["1"])
    }

    @MainActor
    func testOptimisticSendConfirmsOrMarksFailedForRetry() async {
        let me = ChatPerson(id: "me", name: "Abby")
        let thread = ChatThread(me: me, chat: ChatInfo(id: "c1", kind: .direct, title: "Sage", subtitle: "Direct",
                                                       packageRowId: nil, peer: nil), messages: [])
        let failing = Flag()
        let service = ChatService(
            inbox: { fatalError() },
            thread: { _ in thread },
            open: { _ in thread },
            send: { _, body in
                if failing.value { throw PortalError.offline }
                return ChatMessage(id: UUID().uuidString, body: body, createdAt: Date(), authorId: "me", author: me)
            })
        let model = ChatModel(chatId: "c1", service: service)
        await model.load()
        model.draft = "  On my way  "
        XCTAssertTrue(model.canSend)
        await model.send()
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.messages.map(\.body), ["On my way"])
        XCTAssertTrue(model.pending.isEmpty)

        failing.value = true
        model.draft = "Second"
        await model.send()
        XCTAssertEqual(model.pending.count, 1)
        guard case .failed = model.pending[0].status else { return XCTFail("expected a failed message") }

        failing.value = false
        await model.retry(model.pending[0])
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.messages.count, 2)
    }

    func testInboxSearchMatchesTitleOrPackage() {
        let chats = [
            ChatSummary(chatId: "a", kind: .group, title: "Abby & Otto", subtitle: "Club Fair · Cycle 2", preview: nil,
                        updatedAt: nil, unreadCount: 0, packageRowId: "r", peer: nil),
            ChatSummary(chatId: "b", kind: .direct, title: "Sage", subtitle: "Direct", preview: nil,
                        updatedAt: nil, unreadCount: 0, packageRowId: nil, peer: nil),
        ]
        XCTAssertEqual(InboxModel.filter(chats, query: "club").map(\.id), ["a"])
        XCTAssertEqual(InboxModel.filter(chats, query: "sage").map(\.id), ["b"])
        XCTAssertEqual(InboxModel.filter(chats, query: " ").count, 2)
    }

    func testLiveServiceSendsTheWebPanelsRequests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = PortalClient(portal: portal, session: URLSession(configuration: config), cookies: { [] })
        StubProtocol.handler = { _ in
            (200, Data(#"{"data":{"me":{"id":"me","name":"Abby"},"message":{"id":"m9","body":"Hi","createdAt":"2026-10-02T19:00:00.000Z","authorId":"me","author":{"id":"me","name":"Abby"}}}}"#.utf8))
        }
        let sent = try await ChatService.live(client).send("c1", "Hi")
        XCTAssertEqual(sent.id, "m9")
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/hub-chat/c1")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String], ["body": "Hi"])

        XCTAssertEqual(try JSONSerialization.jsonObject(with: PortalJSON.encoder().encode(ChatTarget.group(packageRowId: "r1").body)) as? [String: String],
                       ["kind": "GROUP", "packageRowId": "r1"])
    }

    func testDeepLinks() {
        XCTAssertEqual(MessagesRoute.deepLink(["messages", "c1"], []), DeepLinkMatch(tab: .messages, route: .messages(.conversation(id: "c1"))))
        XCTAssertEqual(MessagesRoute.deepLink(["messages"], []), DeepLinkMatch(tab: .messages, route: nil))
        XCTAssertEqual(MessagesRoute.deepLink(["equipment", "request"], []), DeepLinkMatch(tab: .more, route: .messages(.equipment)))
        XCTAssertEqual(MessagesRoute.deepLink(["livestreams", "ev1"], []), DeepLinkMatch(tab: .more, route: .messages(.livestream(id: "ev1"))))
        XCTAssertNil(MessagesRoute.deepLink(["grades"], []))
    }

    func testLinksInMessagesAreTappableButNotMarkdown() {
        let text = MessageBubble.linked("Slides: https://example.edu/deck **bold**")
        let links = text.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.edu/deck")!])
        XCTAssertTrue(String(text.characters).contains("**bold**"))
    }

    func testAvatarInitials() {
        XCTAssertEqual(Avatar.initials("Abby Example"), "AE")
        XCTAssertEqual(Avatar.initials("Otto"), "O")
        XCTAssertEqual(Avatar.initials(""), "?")
    }
}

/// A mutable flag a `@Sendable` stub closure can read.
final class Flag: @unchecked Sendable {
    var value = false
}
