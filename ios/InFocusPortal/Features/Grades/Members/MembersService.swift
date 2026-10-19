import Foundation

/// The Members page's Portal calls (`app/api/members`). In the sample app (`SampleMode`) it
/// answers from fictional fixtures and saves nothing.
struct MembersService {
    let client: PortalClient

    func members() async throws -> MembersPayload {
        if SampleMode.isOn { return try GradesFixtures.decode(MembersPayload.self, Self.sampleJSON) }
        return try await client.get("api/members")
    }

    /// Saves one note; the Portal answers with the text it kept (cut to 4000 characters).
    func save(_ note: MemberNoteSave) async throws -> MemberNoteSave {
        if SampleMode.isOn { return note }
        return try await client.patch("api/members/notes", body: note)
    }

    static let sampleJSON = #"""
    {"data":{
      "cycles":[{"cycleNumber":1,"focus":"Back to school"},{"cycleNumber":2,"focus":"Sports"}],
      "members":[
        {"id":"u-abby","name":"Abby Example","email":"abby@example.edu",
         "notesByCycle":{"0":"Strong on camera. Wants to try editing.","1":"Great interview list."}},
        {"id":"u-otto","name":"Otto Example","email":"otto@example.edu","notesByCycle":{"2":"Check in about b-roll."}},
        {"id":"u-sage","name":"Sage Example","email":"sage@example.edu","notesByCycle":{}}
      ]
    }}
    """#
}
