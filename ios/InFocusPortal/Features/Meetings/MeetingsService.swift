import Foundation
import Observation

/// The Meetings endpoint, or fictional meetings in the sample app (`SampleMode`).
struct MeetingsService: Sendable {
    var list: @Sendable () async throws -> MeetingsList

    static func live(_ client: PortalClient) -> MeetingsService {
        MeetingsService(list: { try await client.get("api/meetings") })
    }

    static func resolve(_ client: PortalClient) -> MeetingsService {
        SampleMode.isOn ? .stub : .live(client)
    }

    /// Fictional producer meetings for App Review and `-InFocusStubSession` screenshots.
    static let stub = MeetingsService(list: {
        try? await Task.sleep(nanoseconds: 250_000_000)
        return sampleList()
    })

    static func sampleList(now: Date = Date()) -> MeetingsList {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400
        return MeetingsList(
            live: [MeetingSummary(id: "sample-live", title: "Producer meeting", startsAt: now.addingTimeInterval(-10 * 60),
                                  status: "LIVE", isHost: true, canEdit: true, notesStatus: "RECORDING")],
            upcoming: [
                MeetingSummary(id: "sample-soon", title: "Cycle 3 pitch review", startsAt: now.addingTimeInterval(2 * hour),
                               durationMinutes: 30),
                MeetingSummary(id: "sample-next", title: "Producer meeting", startsAt: now.addingTimeInterval(day + hour)),
                MeetingSummary(id: "sample-execs", title: "Show rundown", startsAt: now.addingTimeInterval(2 * day),
                               durationMinutes: 45, access: "INVITE_ONLY", inviteeCount: 4),
            ],
            past: [
                MeetingSummary(id: "sample-past", title: "Producer meeting", startsAt: now.addingTimeInterval(-2 * day),
                               status: "ENDED", notesStatus: "READY"),
                MeetingSummary(id: "sample-past-2", title: "Livestream planning", startsAt: now.addingTimeInterval(-5 * day),
                               durationMinutes: 30, status: "ENDED", notesStatus: "READY"),
            ])
    }
}

/// The meetings list and its load state.
@MainActor @Observable
final class MeetingsModel {
    private(set) var state: Loadable<MeetingsList> = .idle
    private let service: MeetingsService

    init(service: MeetingsService) {
        self.service = service
    }

    func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await service.list())
        } catch {
            if state.value == nil { state = .failed(Loadable<MeetingsList>.message(for: error)) }
        }
    }
}
