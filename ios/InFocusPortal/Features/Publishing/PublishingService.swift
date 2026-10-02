import Foundation

/// Every Portal call the Publishing Queue makes. In a DEBUG stub session
/// (`-InFocusStubSession`) it answers from fictional fixtures instead.
struct PublishingService {
    let client: PortalClient

    private static let queuePath = "api/package-cycle/queue"
    private static let managersPath = "api/package-cycle/queue/managers"

    /// The queue; `candidates` adds final cuts that could be added (producers).
    func queue(candidates: Bool = false) async throws -> QueuePayload {
        #if DEBUG
        if Self.stubbed { return try PublishingFixtures.queue(candidates: candidates) }
        #endif
        let query = candidates ? [URLQueryItem(name: "candidates", value: "1")] : []
        return try await client.get(Self.queuePath, query: query)
    }

    /// Queue, move (a `showDate`) or remove (`queued: false`) a package.
    func update(_ change: QueueUpdate) async throws {
        if Self.stubbed { return }
        let _: PortalJSON.Empty = try await client.post(Self.queuePath, body: change)
    }

    func showPublication(date: String) async throws -> ShowPublicationState {
        #if DEBUG
        if Self.stubbed { return try PublishingFixtures.showPublication(date: date) }
        #endif
        return try await client.get("api/show-roles/publication", query: [URLQueryItem(name: "date", value: date)])
    }

    func managers() async throws -> PublishingManagers {
        #if DEBUG
        if Self.stubbed { return try PublishingFixtures.managers() }
        #endif
        return try await client.get(Self.managersPath)
    }

    func addManager(userId: String) async throws {
        if Self.stubbed { return }
        struct Body: Encodable { let userId: String }
        let _: PortalJSON.Empty = try await client.post(Self.managersPath, body: Body(userId: userId))
    }

    func removeManager(userId: String) async throws {
        if Self.stubbed { return }
        _ = try await client.delete(Self.managersPath, query: [URLQueryItem(name: "userId", value: userId)])
    }

    /// A custom package: ask where the video goes, upload it, then queue it.
    func startCustomUpload(title: String, fileName: String) async throws -> CustomQueueUpload {
        struct Body: Encodable { var action = "init"; let title: String; let fileName: String }
        return try await client.post("api/package-cycle/queue/custom", body: Body(title: title, fileName: fileName))
    }

    func finishCustomUpload(title: String, upload: CustomQueueUpload) async throws {
        struct Body: Encodable { var action = "complete"; let title: String; let mediaId: String; let versionId: String }
        let _: PortalJSON.Empty = try await client.post("api/package-cycle/queue/custom",
                                                         body: Body(title: title, mediaId: upload.mediaId,
                                                                    versionId: upload.versionId))
    }

    static var stubbed: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: "InFocusStubSession") != nil
        #else
        false
        #endif
    }
}
