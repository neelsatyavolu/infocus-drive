import Foundation
import UIKit

/// The password vault's Portal calls (`app/api/vault/*`). Never logs or stores a secret:
/// revealed values live only in the screen's state and the clipboard. The sample app
/// answers from fictional fixtures and reveals nothing real.
struct VaultService {
    let client: PortalClient

    static var stubbed: Bool { SampleMode.isOn }

    /// Full, shared or none. The sample app has full access to its fictional logins.
    func access() async throws -> VaultAccess {
        if Self.stubbed { return VaultAccess(level: .full, canShare: true, canDeleteAny: true) }
        return try await client.get("api/vault/access")
    }

    func entries() async throws -> [VaultEntry] {
        if Self.stubbed { return try VaultFixtures.entries() }
        return try await client.get("api/vault")
    }

    func reveal(_ field: String, of entryId: String) async throws -> String {
        if Self.stubbed { return field == "notes" ? "Sample notes." : "sample-password" }
        struct Body: Encodable { let field: String }
        let answer: VaultRevealedValue = try await client.post("api/vault/\(AdminService.segment(entryId))/reveal",
                                                                body: Body(field: field))
        return answer.value
    }

    func totp(of entryId: String) async throws -> VaultTotp {
        if Self.stubbed { return VaultTotp(code: "123456", secondsRemaining: 18, period: 30) }
        struct Body: Encodable { var field = "totp" }
        return try await client.post("api/vault/\(AdminService.segment(entryId))/reveal", body: Body())
    }

    func activity(of entryId: String) async throws -> [VaultActivity] {
        if Self.stubbed { return try VaultFixtures.activity() }
        return try await client.get("api/vault/\(AdminService.segment(entryId))/activity")
    }

    func create(_ input: VaultEntryInput) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        let _: PortalJSON.Empty = try await client.post("api/vault", body: input)
    }

    func update(_ entryId: String, _ input: VaultEntryInput) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        let _: PortalJSON.Empty = try await client.patch("api/vault/\(AdminService.segment(entryId))", body: input)
    }

    func delete(_ entryId: String) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        try await client.delete("api/vault/\(AdminService.segment(entryId))")
    }

    /// Everyone outside the vault who could be given this login, and who has it now.
    func sharing(of entryId: String) async throws -> (candidates: [VaultPeople.Person], shared: [VaultPeople.Person]) {
        if Self.stubbed { return (VaultFixtures.people, [VaultFixtures.people[0]]) }
        async let candidates: VaultPeople = client.get("api/vault/people")
        async let shared: VaultPeople = client.get("api/vault/\(AdminService.segment(entryId))/shares")
        return (try await candidates.people, try await shared.people)
    }

    func setSharing(of entryId: String, userIds: [String]) async throws {
        if Self.stubbed { return SampleMode.notSaved() }
        struct Body: Encodable { let userIds: [String] }
        let _: VaultPeople = try await client.put("api/vault/\(AdminService.segment(entryId))/shares", body: Body(userIds: userIds))
    }

    /// Copies on this device only and clears itself after a minute and a half.
    @MainActor
    static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(90)])
    }
}

enum VaultFixtures {
    static func entries() throws -> [VaultEntry] {
        try AdminFixtures.decode([VaultEntry].self, entriesJSON)
    }

    static func activity() throws -> [VaultActivity] {
        try AdminFixtures.decode([VaultActivity].self, #"""
        {"data":[{"id":"a1","action":"REVEAL_PASSWORD","actor":"Otto","createdAt":"2026-10-17T19:00:00.000Z"},
                 {"id":"a2","action":"UPDATE","actor":"Sage","createdAt":"2026-10-10T16:30:00.000Z"}]}
        """#)
    }

    static let people = [VaultPeople.Person(id: "u-abby", name: "Abby Example"),
                         VaultPeople.Person(id: "u-kai", name: "Kai Example")]

    static let entriesJSON = #"""
    {"data":[
      {"id":"v-youtube","name":"InFocus YouTube","url":"https://www.youtube.com/","username":"channel@example.edu",
       "hasPassword":true,"hasTotp":true,"hasNotes":true,"updatedAt":"2026-10-10T16:30:00.000Z","updatedBy":"Sage",
       "canDelete":true,"canEdit":true,"canShare":true,"sharedWith":1},
      {"id":"v-insta","name":"Instagram","url":"https://instagram.com/","username":"infocus.example",
       "hasPassword":true,"hasTotp":false,"hasNotes":false,"updatedAt":"2026-09-30T12:00:00Z","updatedBy":null,
       "canDelete":false,"canEdit":true,"canShare":false,"sharedWith":0}]}
    """#
}
