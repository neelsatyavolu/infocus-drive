import Foundation
import Observation

/// The Publishing Queue and every change to it. Each change goes to the
/// Portal (which enforces the max-2 rule), then the queue reloads.
@MainActor @Observable
final class PublishingModel {
    private(set) var state: Loadable<QueuePayload> = .idle
    /// The package an action is running on (its controls show progress).
    private(set) var busyRowId: String?
    /// A failed action's words, shown in an alert.
    var actionError: String?
    /// The last success, for an accessibility announcement; `successCount` triggers haptics.
    private(set) var notice: String?
    private(set) var successCount = 0

    var payload: QueuePayload? { state.value }
    var canEdit: Bool { payload?.canEdit ?? false }
    var live: [QueueLogic.Section] { payload.map(QueueLogic.liveSections) ?? [] }
    var past: [QueueLogic.Section] { payload.map(QueueLogic.pastSections) ?? [] }

    func package(_ rowId: String) -> QueuePackage? {
        payload?.packages.first { $0.id == rowId }
    }

    /// Upcoming shows plus past air dates that still hold packages (the Past shows sheet's choices).
    var moveChoices: [UpcomingShow] {
        guard let payload else { return [] }
        let past = past.map { UpcomingShow(date: $0.date, label: QueueLogic.showLabel($0.date)) }
        let seen = Set(past.map(\.date))
        return past + payload.upcomingShows.filter { !seen.contains($0.date) }
    }

    func load(_ service: PublishingService, candidates: Bool = false) async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await service.queue(candidates: candidates))
        } catch PortalError.forbidden {
            state = .failed("The Publishing Queue is for producers and website managers.")
        } catch {
            if state.value == nil { state = .failed(Loadable<QueuePayload>.message(for: error)) }
        }
    }

    /// Move to `date`, or nil for "next empty show" (the server picks it).
    @discardableResult
    func move(_ package: QueuePackage, to date: String?, service: PublishingService) async -> Bool {
        if let date, let all = payload?.packages, !QueueLogic.canPlace(on: date, in: all, moving: package.id) {
            actionError = QueueLogic.showFullMessage
            return false
        }
        return await run(package.id, success: "Moved.", service: service) {
            try await service.update(QueueUpdate(rowId: package.id, queued: true, showDate: date))
        }
    }

    @discardableResult
    func remove(_ package: QueuePackage, service: PublishingService) async -> Bool {
        await run(package.id, success: "Removed from the queue.", service: service) {
            try await service.update(QueueUpdate(rowId: package.id, queued: false, showDate: nil))
        }
    }

    /// Adds a final cut on the next empty show (automatic assignment never stacks).
    @discardableResult
    func add(_ candidate: QueueCandidate, service: PublishingService) async -> Bool {
        await run(candidate.id, success: "Added to the publishing queue.", service: service, candidates: true) {
            try await service.update(QueueUpdate(rowId: candidate.id, queued: true, showDate: nil))
        }
    }

    /// After a custom upload finished.
    func added(service: PublishingService) async {
        succeed("Added to the publishing queue.")
        await load(service)
    }

    private func succeed(_ message: String) {
        notice = message
        successCount += 1
    }

    private func run(_ id: String, success: String, service: PublishingService, candidates: Bool = false,
                     _ action: () async throws -> Void) async -> Bool {
        busyRowId = id
        defer { busyRowId = nil }
        do {
            try await action()
            succeed(success)
            await load(service, candidates: candidates)
            return true
        } catch {
            actionError = Loadable<QueuePayload>.message(for: error)
            return false
        }
    }
}
