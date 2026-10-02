import Foundation

/// The Messages endpoints, or fictional data in the sample app (`SampleMode`).
struct ChatService: Sendable {
    var inbox: @Sendable () async throws -> ChatInbox
    var thread: @Sendable (_ chatId: String) async throws -> ChatThread
    var open: @Sendable (_ target: ChatTarget) async throws -> ChatThread
    var send: @Sendable (_ chatId: String, _ body: String) async throws -> ChatMessage

    static func live(_ client: PortalClient) -> ChatService {
        ChatService(
            inbox: { try await client.get("api/hub-chat") },
            thread: { id in try await client.get("api/hub-chat/\(id)") },
            open: { target in try await client.post("api/hub-chat", body: target.body) },
            send: { id, body in
                let sent: SentChatMessage = try await client.post("api/hub-chat/\(id)", body: ["body": body])
                return sent.message
            }
        )
    }

    static func resolve(_ client: PortalClient) -> ChatService {
        if FeatureStub.isOn { return .stub }
        return .live(client)
    }
}
