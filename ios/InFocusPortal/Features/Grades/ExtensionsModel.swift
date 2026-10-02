import Foundation
import Observation

/// Extension requests and every action on them, for `ExtensionsScreen` and
/// `ExtensionRequestScreen`. After each change it reloads and refreshes the
/// More badge (requests waiting on this person).
@MainActor @Observable
final class ExtensionsModel {
    private(set) var state: Loadable<ExtensionRequestsPayload> = .idle
    /// The request an action is running on (its buttons show progress).
    private(set) var busyRequestId: String?
    /// A failed action's words, shown in an alert.
    var actionError: String?

    func load(_ service: GradesService) async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await service.extensionRequests())
        } catch PortalError.forbidden {
            state = .failed("Extension requests aren't available for this account.")
        } catch {
            if state.value == nil { state = .failed(Loadable<ExtensionRequestsPayload>.message(for: error)) }
        }
    }

    func respond(_ request: ExtensionRequest, agreed: Bool, service: GradesService, badges: BadgeCenter) async {
        await run(request.id, service: service, badges: badges) {
            try await service.respondAsMember(requestId: request.id, agreed: agreed)
        }
    }

    /// `terms` only when this producer is the first to approve.
    func approve(_ request: ExtensionRequest, terms: (days: Double, userIds: [String])?, service: GradesService,
                 badges: BadgeCenter) async -> Bool {
        await run(request.id, service: service, badges: badges) {
            try await service.decideAsProducer(ProducerDecision(requestId: request.id, approved: true,
                                                                grantedDays: terms?.days, grantedUserIds: terms?.userIds))
        }
    }

    func deny(_ request: ExtensionRequest, reason: String, service: GradesService, badges: BadgeCenter) async -> Bool {
        await run(request.id, service: service, badges: badges) {
            try await service.decideAsProducer(ProducerDecision(requestId: request.id, approved: false, reason: reason))
        }
    }

    /// Files a request; throws so the form can show the Portal's message in place.
    func submit(_ request: NewExtensionRequest, service: GradesService, badges: BadgeCenter) async throws {
        try await service.requestExtension(request)
        await load(service)
        await badges.refresh(using: service.client)
    }

    @discardableResult
    private func run(_ id: String, service: GradesService, badges: BadgeCenter,
                     _ action: () async throws -> Void) async -> Bool {
        busyRequestId = id
        defer { busyRequestId = nil }
        do {
            try await action()
            await load(service)
            await badges.refresh(using: service.client)
            return true
        } catch {
            actionError = Loadable<ExtensionRequestsPayload>.message(for: error)
            return false
        }
    }
}
