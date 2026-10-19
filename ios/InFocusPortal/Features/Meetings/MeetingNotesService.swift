import Foundation

/// The notes page's Portal calls (`src/lib/meetings/client/api.ts`): the meeting, its
/// transcript from the Drive, every producer (for the invite list) and saving the list.
/// The sample app answers with fictional notes.
struct MeetingNotesService {
    let client: PortalClient

    static var stubbed: Bool { SampleMode.isOn }

    private static func path(_ id: String) -> String {
        // PortalClient escapes the path itself; a "/" could never be part of an id.
        "api/meetings/\(id.replacingOccurrences(of: "/", with: ""))"
    }

    func detail(_ id: String) async throws -> MeetingDetail {
        if Self.stubbed { return try MeetingNotesFixtures.detail(id: id) }
        let answer: MeetingDetailResponse = try await client.get(Self.path(id))
        return answer.meeting
    }

    func transcript(_ id: String) async throws -> String {
        if Self.stubbed { return MeetingNotesFixtures.transcript }
        let answer: MeetingTranscript = try await client.get("\(Self.path(id))/transcript")
        return answer.markdown
    }

    func people() async throws -> [MeetingPerson] {
        if Self.stubbed { return MeetingNotesFixtures.people }
        let answer: MeetingPeople = try await client.get("api/meetings/people")
        return answer.people
    }

    /// Replaces who's invited (hosts only, before the meeting is over).
    func setInvitees(_ id: String, userIds: [String]) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let inviteeUserIds: [String] }
        let _: PortalJSON.Empty = try await client.patch(Self.path(id), body: Body(inviteeUserIds: userIds))
    }
}

/// Fictional notes for the sample app and tests.
enum MeetingNotesFixtures {
    static let people = [MeetingPerson(id: "u-otto", name: "Otto"), MeetingPerson(id: "u-sage", name: "Sage"),
                         MeetingPerson(id: "u-abby", name: "Abby")]

    static let transcript = "**Sage:** Let's start with the rundown.\n**Otto:** Cycle 3 pitches are in."

    static func detail(id: String) throws -> MeetingDetail {
        let json = detailJSON.replacingOccurrences(of: "\"id\":\"m-notes\"", with: "\"id\":\"\(id)\"")
        return try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<MeetingDetailResponse>.self,
                                               from: Data(json.utf8)).data.meeting
    }

    static let detailJSON = #"""
    {"data":{"meeting":{"id":"m-notes","title":"Producer meeting","startsAt":"2026-10-12T04:15:00.000Z",
      "joinOpensAt":"2026-10-12T04:10:00.000Z","durationMinutes":60,"status":"ENDED","access":"OPEN","inviteeCount":0,
      "seriesKey":"producers","isHost":true,"canEdit":false,"notesEnabled":true,"quickAccess":false,"notesStatus":"READY",
      "participantCount":7,"agendaCount":3,"createdByName":"Sage",
      "notesSummary":"# Summary\nThe team planned **Cycle 3** and the Friday show.\n\n# Action items\n- Otto books the gym for the A-roll\n- Sage sends the rundown by Thursday",
      "notesError":null,"invitees":[],"hasTranscript":true,
      "startedAt":"2026-10-12T04:16:00.000Z","endedAt":"2026-10-12T05:02:00.000Z"}}}
    """#
}
