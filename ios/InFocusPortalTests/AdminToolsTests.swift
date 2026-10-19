import XCTest
@testable import InFocusPortal

/// Admin (`/admin`): decoding every `api/platform/*` answer the app reads, and the dashboard's rules.
final class AdminModelTests: XCTestCase {
    func testDecodesAccessAndPermissions() throws {
        let access = try AdminFixtures.access()
        XCTAssertEqual(access.role, "SUPER_ADMIN")
        XCTAssertTrue(access.permissions.canManageAllowedEmails)
        XCTAssertTrue(access.permissions.canManagePlatformRoles)
        // A student: no role, missing permissions read as false.
        let student = try AdminFixtures.decode(PlatformAccess.self, #"{"data":{"email":"abby@example.edu","role":null,"permissions":{}}}"#)
        XCTAssertNil(student.role)
        XCTAssertFalse(student.permissions.canManageAllowedEmails)
    }

    func testDecodesStatsAndFormatsStorage() throws {
        let stats = try AdminFixtures.stats()
        XCTAssertEqual(stats.totals.users, 42)
        XCTAssertEqual(stats.totals.activeShareLinks, 4)
        XCTAssertTrue(stats.storage.isEstimated)
        XCTAssertEqual(AdminFormat.storage(stats.storage.estimatedBytes), "1.25 TB")
        XCTAssertEqual(AdminFormat.storage(52_428_800), "52.43 MB")
        XCTAssertEqual(AdminFormat.storage(2_500_000_000), "2.50 GB")
        XCTAssertEqual(AdminFormat.storage(1_500), "2 KB")
    }

    func testDecodesAccessRequestsWithEitherDateShape() throws {
        let requests = try AdminFixtures.accessRequests()
        XCTAssertEqual(requests.filter(\.isPending).map(\.id), ["req-rio", "req-kai"])
        XCTAssertEqual(requests[1].label, "kai@example.edu") // no name: the email
        XCTAssertEqual(requests[0].label, "Rio Example")
        XCTAssertNotNil(requests[2].decidedAt)
    }

    func testDecodesPeopleRolesAndLabels() throws {
        let people = try AdminFixtures.people()
        XCTAssertEqual(people.map(\.label), ["Abby Example", "Otto", "Sage Example", "Juno Example"])
        XCTAssertFalse(people[3].hasSignedIn) // approved, never signed in
        XCTAssertTrue(people[0].hasSignedIn)
        let roles = try AdminFixtures.roles()
        XCTAssertEqual(roles.map(\.platformRole), [.associateProducer, .executiveProducer, .adviser])
    }

    func testProducerTeamGroupsByRoleWithNames() throws {
        let team = ProducerTeam(roles: try AdminFixtures.roles(), people: try AdminFixtures.people(), canManage: true)
        XCTAssertEqual(team.groups.map(\.role), [.adviser, .executiveProducer, .associateProducer])
        let otto = try XCTUnwrap(team.roles.first { $0.email == "otto@example.edu" })
        XCTAssertEqual(team.label(for: otto), "Otto")
        let adviser = try XCTUnwrap(team.roles.first { $0.role == "ADVISER" })
        XCTAssertEqual(team.label(for: adviser), "adviser@example.edu") // not in people: the email
        XCTAssertEqual(AssignableRole.allCases.map(\.rawValue), ["ASSOCIATE_PRODUCER", "EXECUTIVE_PRODUCER", "ADVISER"])
    }

    func testPeopleSearchMatchesNicknameNameAndEmail() throws {
        let people = try AdminFixtures.people()
        XCTAssertEqual(PeopleSearch.filter(people, "  OTTO ").map(\.id), ["u-otto"])
        XCTAssertEqual(PeopleSearch.filter(people, "juno@").map(\.id), ["pending_7f9c"])
        XCTAssertEqual(PeopleSearch.filter(people, "").count, 4)
    }

    func testDecodesBackupsAndUnconfigured() throws {
        let backups = try AdminFixtures.backups()
        XCTAssertTrue(backups.configured)
        XCTAssertEqual(backups.latest?.ok, true)
        XCTAssertEqual(backups.dumps.first?.fileName, "2026-10-18.dump")
        let off = try AdminFixtures.decode(BackupStatus.self, #"{"data":{"configured":false}}"#)
        XCTAssertFalse(off.configured)
        XCTAssertTrue(off.dumps.isEmpty)
    }

    func testDecodesSmallAnswers() throws {
        XCTAssertEqual(try AdminFixtures.decode(ProgramSettings.self, #"{"data":{"cyclesPerSemester":4,"canEdit":false}}"#),
                       ProgramSettings(cyclesPerSemester: 4, canEdit: false))
        XCTAssertEqual(try AdminFixtures.decode(AddPersonResult.self, #"{"data":{"email":"rio@example.edu","emailed":1}}"#).emailed, 1)
        XCTAssertEqual(try AdminFixtures.viewAsPeople().map(\.label), ["Abby Example", "Otto"])
    }

    func testWhenShowsTheYearOnlyForOtherYears() throws {
        let utc = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(PortalJSON.date(from: "2026-10-18T12:00:00Z"))
        let thisYear = try XCTUnwrap(PortalJSON.date(from: "2026-10-14T15:05:00Z"))
        let lastYear = try XCTUnwrap(PortalJSON.date(from: "2025-12-30T09:00:00Z"))
        func clean(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(clean(AdminFormat.when(thisYear, now: now, timeZone: utc)), "Oct 14, 3:05 PM")
        XCTAssertEqual(clean(AdminFormat.when(lastYear, now: now, timeZone: utc)), "Dec 30, 2025, 9:00 AM")
        XCTAssertTrue(AdminFormat.isEmail("abby@example.edu"))
        XCTAssertFalse(AdminFormat.isEmail("abby@example"))
        XCTAssertFalse(AdminFormat.isEmail("abby example@example.edu"))
    }

    func testViewAsBodyAndCookie() throws {
        XCTAssertEqual(String(data: try ViewAsSwitch.body("u-otto"), encoding: .utf8), #"{"userId":"u-otto"}"#)
        XCTAssertEqual(String(data: try ViewAsSwitch.body(nil), encoding: .utf8), #"{"userId":null}"#)
        let now = Date()
        func cookie(_ value: String, expires: Date?) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: ViewAsSwitch.cookieName, .value: value,
                                                            .domain: "portal.example.edu", .path: "/"]
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)!
        }
        XCTAssertTrue(ViewAsSwitch.isActive(cookie("token", expires: now.addingTimeInterval(60)), now: now))
        XCTAssertFalse(ViewAsSwitch.isActive(cookie("token", expires: now.addingTimeInterval(-60)), now: now))
        XCTAssertFalse(ViewAsSwitch.isActive(cookie("", expires: nil), now: now))
        XCTAssertEqual(ViewAsSwitch.filter(try AdminFixtures.viewAsPeople(), "abby").map(\.id), ["u-abby"])
    }

    func testDecodesViewAsStatus() throws {
        let on = try AdminFixtures.decode(ViewAsStatus.self, #"""
        {"data":{"active":true,"allowed":true,"realUser":{"id":"u-sage","name":"Sage Example","email":"sage@example.edu"},
          "actingAs":{"id":"u-abby","name":"Abby Example","email":"abby@example.edu"}}}
        """#)
        XCTAssertTrue(on.active)
        XCTAssertTrue(on.allowed)
        XCTAssertEqual(on.actingAsLabel, "Abby Example")
        XCTAssertEqual(on.realUser?.label, "Sage Example")
        let off = try AdminFixtures.decode(ViewAsStatus.self, #"""
        {"data":{"active":false,"allowed":false,"realUser":{"id":"u-otto","name":null,"email":"otto@example.edu"},"actingAs":null}}
        """#)
        XCTAssertFalse(off.active)
        XCTAssertFalse(off.allowed)
        XCTAssertNil(off.actingAs)
        XCTAssertEqual(off.realUser?.label, "otto@example.edu")
        XCTAssertEqual(off.actingAsLabel, "someone else")
    }
}

/// Admin's writes send what the web sends.
final class AdminServiceTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func client() -> PortalClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return PortalClient(portal: portal, session: URLSession(configuration: config), cookies: { [] })
    }

    override func setUp() { SampleMode.set(false) }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    private func body() throws -> [String: Any] {
        let data = try XCTUnwrap(StubProtocol.lastRequest?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDecisionsAndApproveAll() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"id":"req-rio","status":"APPROVED"}}"#.utf8)) }
        try await AdminService(client: client()).decide("req-rio", approve: true)
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/platform/access-requests")
        XCTAssertEqual(try body()["status"] as? String, "APPROVED")
        XCTAssertEqual(try body()["id"] as? String, "req-rio")

        StubProtocol.handler = { _ in (200, Data(#"{"data":{"approvedCount":2}}"#.utf8)) }
        let count = try await AdminService(client: client()).approveAllPending()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try body()["action"] as? String, "APPROVE_ALL_PENDING")
    }

    func testNicknameClearSendsNullAndRoleRemovalUsesQuery() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"id":"u-otto"}}"#.utf8)) }
        try await AdminService(client: client()).setNickname(nil, for: "u-otto")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/platform/users/u-otto")
        XCTAssertTrue(try body()["nickname"] is NSNull)

        StubProtocol.handler = { _ in (200, Data(#"{"data":{"deleted":true}}"#.utf8)) }
        try await AdminService(client: client()).removeRole(email: "otto@example.edu")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.query, "email=otto@example.edu")
    }

    func testStatusEndpointsUseTheirPaths() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"data":{"active":false,"allowed":true,"realUser":{"id":"u-sage","name":"Sage","email":null},"actingAs":null}}"#.utf8))
        }
        let status = try await AdminService(client: client()).viewAsStatus()
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/auth/view-as/status")
        XCTAssertTrue(status.allowed)

        StubProtocol.handler = { _ in (200, Data(#"{"data":{"level":"shared","canShare":false,"canDeleteAny":false}}"#.utf8)) }
        let access = try await VaultService(client: client()).access()
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/vault/access")
        XCTAssertEqual(access.level, .shared)

        StubProtocol.handler = { _ in (200, Data(ManagersFixtures.overviewJSON.utf8)) }
        let overview = try await ManagersService(client: client()).overview()
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/managers")
        XCTAssertEqual(overview.ordered.first?.area, .equipment)
    }

    func testAddPersonAndForbidden() async throws {
        StubProtocol.handler = { _ in (201, Data(#"{"data":{"email":"rio@example.edu","emailed":0}}"#.utf8)) }
        let result = try await AdminService(client: client()).addPerson(name: "Rio Example", email: "rio@example.edu", sendInvite: false)
        XCTAssertEqual(result.emailed, 0)
        XCTAssertEqual(try body()["sendInvite"] as? Bool, false)

        StubProtocol.handler = { _ in (403, Data(#"{"error":{"message":"Forbidden"}}"#.utf8)) }
        do {
            _ = try await AdminService(client: client()).stats()
            XCTFail("expected forbidden")
        } catch PortalError.forbidden {
            // shown as "not available"
        }
    }
}

/// Managers (`/managers`, `/managers/social-media`).
final class ManagersTests: XCTestCase {
    func testDecodesNestedAndFlatRosters() throws {
        let nested = try AdminFixtures.decode(ManagerRoster.self, #"""
        {"data":{"managers":[{"id":"m1","userId":"u-rio","user":{"id":"u-rio","name":"Rio Example","nickname":"Rio","email":"rio@example.edu"},
          "createdAt":"2026-10-01T00:00:00.000Z"}]}}
        """#)
        XCTAssertEqual(nested.managers.first?.name, "Rio")
        XCTAssertEqual(nested.managers.first?.email, "rio@example.edu")
        XCTAssertTrue(nested.candidates.isEmpty)
        let flat = try AdminFixtures.decode(ManagerRoster.self, #"""
        {"data":{"managers":[{"userId":"u-juno","name":"Juno","email":"juno@example.edu"}],
          "candidates":[{"id":"u-kai","name":"Kai","email":"kai@example.edu"}]}}
        """#)
        XCTAssertEqual(flat.managers.map(\.label), ["Juno"])
        XCTAssertEqual(flat.candidates.map(\.id), ["u-kai"])
    }

    func testDecodesOverviewAndSkipsUnknownAreas() throws {
        let overview = try ManagersFixtures.overview()
        XCTAssertFalse(overview.isProducer)
        XCTAssertEqual(overview.yourAreas, [.equipment])
        XCTAssertEqual(overview.areas.map(\.area), [.equipment, .livestreams, .website, .socialMedia])
        XCTAssertEqual(overview.areas[0].people.map(\.name), ["Rio"])
        XCTAssertTrue(overview.areas[0].yours)
        XCTAssertFalse(overview.areas[2].canOpen)
        // A newer Portal's area (and its id in yourAreas) is skipped, not a decoding failure.
        let newer = try AdminFixtures.decode(ManagersOverview.self, #"""
        {"data":{"isProducer":true,"yourAreas":["podcast"],"areas":[
          {"id":"podcast","title":"Podcast","tool":"Podcast Desk","description":"","href":"/podcast","access":"",
           "canOpen":true,"yours":true,"people":[]},
          {"id":"website","title":"Website","tool":"Publishing Queue","description":"Shows.","href":"/publishing-queue",
           "access":"Producers","canOpen":true,"yours":false,"people":[]}]}}
        """#)
        XCTAssertTrue(newer.isProducer)
        XCTAssertEqual(newer.yourAreas, [])
        XCTAssertEqual(newer.areas.map(\.area), [.website])
    }

    func testOrdersYoursThenOpenThenLockedLikeTheWeb() {
        func area(_ id: ManagerArea, open: Bool, yours: Bool) -> ManagersOverview.Area {
            .init(area: id, title: id.rawValue, tool: "", description: "", access: "Producers",
                  canOpen: open, yours: yours, people: [])
        }
        // The Portal's fixed order: equipment, livestreams, website, social media.
        let overview = ManagersOverview(isProducer: false, yourAreas: [.socialMedia], areas: [
            area(.equipment, open: false, yours: false), area(.livestreams, open: true, yours: false),
            area(.website, open: false, yours: false), area(.socialMedia, open: true, yours: true)])
        XCTAssertEqual(overview.ordered.map(\.area), [.socialMedia, .livestreams, .equipment, .website])
        XCTAssertEqual(overview.areas[0].accessLine, "Producers. Ask a producer if you need it.")
        XCTAssertEqual(overview.areas[1].accessLine, "Producers")
        XCTAssertEqual(overview.summary, "Each manager role has its own tool. Choose yours to open it.")
        XCTAssertEqual(ManagersOverview(isProducer: false, yourAreas: [], areas: []).summary,
                       "You're not a manager yet. Producers appoint managers from each tool.")
        XCTAssertTrue(ManagersOverview(isProducer: true, yourAreas: [], areas: []).summary.hasPrefix("You're a producer"))
        XCTAssertEqual(ManagerArea.socialMedia.roleName, "Social media manager")
    }

    func testNamesLineShowsFourNames() {
        func people(_ names: [String]) -> ManagersOverview.Area {
            .init(area: .equipment, title: "", tool: "", description: "", access: "", canOpen: true, yours: false,
                  people: names.enumerated().map { .init(userId: "u\($0.offset)", name: $0.element) })
        }
        XCTAssertEqual(people([]).namesLine, "No one appointed yet")
        XCTAssertEqual(people(["Abby", "A member", "Otto", "Sage", "Rio", "Kai"]).namesLine, "Abby, A member, Otto, Sage +2 more")
        XCTAssertEqual(people(["Abby", "Otto"]).namesLine, "Abby, Otto")
    }

    func testAreasOpenTheirNativeTools() {
        XCTAssertEqual(ManagerArea.allCases.map(\.route), [.messages(.equipment), .messages(.livestreams),
                                                          .publishing(.home), .admin(.socialMedia)])
        XCTAssertEqual(ManagerArea.socialMedia.rosterPath, "api/managers/social-media")
    }
}

/// The password vault (`/passwords`).
final class VaultTests: XCTestCase {
    func testDecodesEntries() throws {
        let entries = try VaultFixtures.entries()
        let youtube = entries[0]
        XCTAssertEqual(youtube.host, "youtube.com")
        XCTAssertTrue(youtube.hasTotp)
        XCTAssertEqual(youtube.sharedWith, 1)
        XCTAssertEqual(entries[1].updatedBy, nil)
        XCTAssertFalse(entries[1].canDelete)
        let unsafe = try AdminFixtures.decode([VaultEntry].self, #"""
        {"data":[{"id":"v","name":"X","url":"javascript:alert(1)","username":null,"hasPassword":false,"hasTotp":false,
          "hasNotes":false,"updatedAt":"2026-10-01T00:00:00Z","updatedBy":null,"canDelete":false,"canEdit":false,
          "canShare":false,"sharedWith":0}]}
        """#)
        XCTAssertNil(unsafe[0].website) // only http(s) links open
    }

    func testDecodesRevealsActivityAndPeople() throws {
        let value = try AdminFixtures.decode(VaultRevealedValue.self, #"{"data":{"field":"password","value":"s3cret"}}"#)
        XCTAssertEqual(value.value, "s3cret")
        let totp = try AdminFixtures.decode(VaultTotp.self, #"{"data":{"field":"totp","code":"123456","secondsRemaining":12,"period":30}}"#)
        XCTAssertEqual(totp, VaultTotp(code: "123456", secondsRemaining: 12, period: 30))
        XCTAssertEqual(VaultTotp.grouped("123456"), "123 456")
        XCTAssertEqual(VaultTotp.grouped("12ab"), "12ab")
        XCTAssertEqual(try VaultFixtures.activity().map(\.label), ["Viewed password", "Edited"])
        let people = try AdminFixtures.decode(VaultPeople.self, #"{"data":{"people":[{"id":"u-abby","name":"Abby"}]}}"#)
        XCTAssertEqual(people.people.map(\.name), ["Abby"])
    }

    func testDecodesAccessLevels() throws {
        let full = try AdminFixtures.decode(VaultAccess.self, #"{"data":{"level":"full","canShare":true,"canDeleteAny":true}}"#)
        XCTAssertEqual(full, VaultAccess(level: .full, canShare: true, canDeleteAny: true))
        XCTAssertTrue(full.isFull)
        let shared = try AdminFixtures.decode(VaultAccess.self, #"{"data":{"level":"shared","canShare":false,"canDeleteAny":false}}"#)
        XCTAssertFalse(shared.isFull)
        XCTAssertTrue(shared.canOpen)
        let none = try AdminFixtures.decode(VaultAccess.self, #"{"data":{"level":"none","canShare":false,"canDeleteAny":false}}"#)
        XCTAssertEqual(none, .noAccess)
        XCTAssertFalse(none.canOpen)
        let newer = try AdminFixtures.decode(VaultAccess.self, #"{"data":{"level":"auditor"}}"#)
        XCTAssertEqual(newer, .noAccess) // unknown levels open nothing
    }

    func testSecretModesMatchTheWebForm() {
        XCTAssertEqual(VaultEntryInput.secret(.remove, "", editing: true), "")
        XCTAssertNil(VaultEntryInput.secret(.keep, "typed", editing: true))
        XCTAssertNil(VaultEntryInput.secret(.replace, "", editing: true)) // empty while editing: left alone
        XCTAssertEqual(VaultEntryInput.secret(.replace, "", editing: false), "")
        XCTAssertEqual(VaultEntryInput.secret(.replace, "new", editing: true), "new")
    }

    func testEditBodyLeavesOutUntouchedFields() throws {
        let input = VaultEntryInput(name: "Instagram", url: "instagram.com", username: "infocus", password: nil, totp: "", notes: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(input)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["name", "url", "username", "totp"])
        XCTAssertEqual(json["totp"] as? String, "")
    }

    func testStrongPasswordsHaveEveryKind() {
        let password = VaultEntryInput.strongPassword()
        XCTAssertEqual(password.count, 20)
        XCTAssertTrue(password.contains { $0.isLowercase })
        XCTAssertTrue(password.contains { $0.isUppercase })
        XCTAssertTrue(password.contains { $0.isNumber })
        XCTAssertTrue(password.contains { "!@#$%^&*-_=+?".contains($0) })
        XCTAssertNotEqual(password, VaultEntryInput.strongPassword())
    }

    func testSearchAndSharedFilter() throws {
        let entries = try VaultFixtures.entries()
        XCTAssertEqual(VaultSearch.filter(entries, "insta", sharedOnly: false).map(\.id), ["v-insta"])
        XCTAssertEqual(VaultSearch.filter(entries, "channel@", sharedOnly: false).map(\.id), ["v-youtube"])
        XCTAssertEqual(VaultSearch.filter(entries, "", sharedOnly: true).map(\.id), ["v-youtube"])
        XCTAssertEqual(VaultSearch.filter(entries, "insta", sharedOnly: true), [])
    }

    func testRevealPostsTheField() async throws {
        SampleMode.set(false)
        defer { StubProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = PortalClient(portal: URL(string: "https://portal.example.edu")!,
                                  session: URLSession(configuration: config), cookies: { [] })
        StubProtocol.handler = { _ in (200, Data(#"{"data":{"field":"notes","value":"Recovery codes"}}"#.utf8)) }
        let notes = try await VaultService(client: client).reveal("notes", of: "v-youtube")
        XCTAssertEqual(notes, "Recovery codes")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/vault/v-youtube/reveal")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
}

/// Settings (`/settings`): profile, email notification preferences, PINs, signature.
final class SettingsNativeTests: XCTestCase {
    func testPreferencesDefaultMissingFieldsAndSendNullEmail() throws {
        let partial = try AdminFixtures.decode(NotificationPreferences.self, #"{"data":{"emailEnabled":false,"notificationEmail":null}}"#)
        XCTAssertFalse(partial.emailEnabled)
        XCTAssertTrue(partial.emailAnnouncementsEnabled)
        XCTAssertFalse(partial.emailGradesEnabled)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(partial)) as? [String: Any])
        XCTAssertEqual(json.count, 9) // a PUT always sends every field
        XCTAssertTrue(json["notificationEmail"] is NSNull)
        XCTAssertEqual(partial.settingEmail(.grades, true).emailGradesEnabled, true)
        XCTAssertEqual(partial.settingEmail(.grades, true).email(.grades), true)
        XCTAssertFalse(partial.email(.grades)) // the original is unchanged
    }

    func testDecodesProfilePinsAndSignature() throws {
        let profile = try AdminFixtures.decode(ProfileInfo.self,
                                               #"{"data":{"email":"abby@example.edu","name":"Abby Example","nickname":null,"sampleOnly":false}}"#)
        XCTAssertEqual(profile.name, "Abby Example")
        XCTAssertNil(profile.nickname)
        XCTAssertEqual(try AdminFixtures.decode(AccessPin.self, #"{"data":{"pin":"482913"}}"#).pin, "482913")
        XCTAssertNil(try AdminFixtures.decode(AccessPin.self, #"{"data":{"pin":null}}"#).pin)
        XCTAssertNil(try AdminFixtures.decode(SignatureInfo.self, #"{"data":{"signature":null}}"#).signature)
        XCTAssertEqual(AccessPinKind.classBoard.path, "api/class-board/pin")
    }

    func testSignatureDataURLRoundTrip() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let url = try XCTUnwrap(SignatureInfo.dataURL(png: png))
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(SignatureInfo.pngData(url), png)
        XCTAssertNil(SignatureInfo.pngData("data:image/jpeg;base64,AAAA"))
        XCTAssertNil(SignatureInfo.dataURL(png: Data(count: 400_000))) // over the Portal's limit
    }
}

/// Meeting notes (`/meetings/<id>`).
final class MeetingNotesTests: XCTestCase {
    func testDecodesTheDetail() throws {
        let meeting = try MeetingNotesFixtures.detail(id: "m-notes")
        XCTAssertEqual(meeting.title, "Producer meeting")
        XCTAssertEqual(meeting.participantCount, 7)
        XCTAssertTrue(meeting.hasTranscript)
        XCTAssertFalse(meeting.canEditInvitees) // host, but the meeting is over
        XCTAssertNotNil(meeting.endedAt)
        XCTAssertEqual(meeting.durationLabel, "1 h")
        XCTAssertNil(meeting.accessLabel)
        let failed = try PortalJSON.decoder().decode(MeetingDetail.self, from: Data(#"""
        {"id":"m2","title":"Rundown","startsAt":"2026-10-12T04:15:00Z","durationMinutes":45,"status":"ENDED",
         "access":"EXECS_ONLY","notesStatus":"FAILED","notesError":"No audio","invitees":[{"id":"u-sage","name":"Sage"}]}
        """#.utf8))
        XCTAssertEqual(failed.notesMessage, "Notes couldn't be made for this meeting.")
        XCTAssertEqual(failed.accessLabel, "Execs only")
        XCTAssertEqual(failed.invitees.map(\.name), ["Sage"])
        XCTAssertFalse(failed.hasTranscript)
        XCTAssertEqual(failed.durationLabel, "45 min")
    }

    func testDecodesTranscriptAndPeople() throws {
        let transcript = try AdminFixtures.decode(MeetingTranscript.self, #"{"data":{"markdown":"**Sage:** Hi"}}"#)
        XCTAssertEqual(transcript.markdown, "**Sage:** Hi")
        let people = try AdminFixtures.decode(MeetingPeople.self, #"{"data":{"people":[{"id":"u-otto","name":"Otto"}]}}"#)
        XCTAssertEqual(people.people.map(\.id), ["u-otto"])
    }

    func testParsesSummaryMarkdownLikeTheWeb() {
        let sections = NotesMarkdown.parse("Intro line\nwraps here\n\n# Decisions\n- One\n* Two\n2. Three\nAfter\n## Empty\n#NotAHeading")
        XCTAssertEqual(sections, [
            .init(heading: nil, blocks: [.paragraph("Intro line wraps here")]),
            .init(heading: "Decisions", blocks: [.list(["One", "Two", "Three"]), .paragraph("After")]),
            .init(heading: "Empty", blocks: [.paragraph("#NotAHeading")]),
        ])
        XCTAssertEqual(NotesMarkdown.heading("### Next steps"), "Next steps")
        XCTAssertNil(NotesMarkdown.heading("####### Too deep"))
        XCTAssertNil(NotesMarkdown.bullet("-no space"))
    }

    func testInlineBoldKeepsEverythingElseLiteral() {
        let text = NotesMarkdown.inline("**Otto** books the [gym](x) **")
        XCTAssertEqual(String(text.characters), "Otto books the [gym](x) ")
        let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(bold.count, 1)
    }
}

/// Every Portal path this area now opens natively.
final class AdminToolsDeepLinkTests: XCTestCase {
    private let portal = URL(string: "https://portal.example.edu")!

    private func resolve(_ path: String) -> DeepLinkMatch {
        DeepLink.resolve(URL(string: "https://portal.example.edu\(path)")!, portal: portal)
    }

    func testAdminManagersAndPasswordsOpenNatively() {
        XCTAssertEqual(resolve("/admin"), DeepLinkMatch(tab: .more, route: .admin(.home)))
        XCTAssertEqual(resolve("/admin#system"), DeepLinkMatch(tab: .more, route: .admin(.home)))
        XCTAssertEqual(resolve("/managers"), DeepLinkMatch(tab: .more, route: .admin(.managers)))
        XCTAssertEqual(resolve("/managers/social-media"), DeepLinkMatch(tab: .more, route: .admin(.socialMedia)))
        XCTAssertEqual(resolve("/passwords"), DeepLinkMatch(tab: .more, route: .admin(.passwords)))
        XCTAssertEqual(resolve("/settings"), DeepLinkMatch(tab: .more, route: .more(.settings)))
        XCTAssertNil(AdminRoute.deepLink(["admin", "extra"], []))
        XCTAssertNil(AdminRoute.deepLink(["managers", "unknown"], []))
    }

    func testMeetingNotesOpenNatively() {
        XCTAssertEqual(resolve("/meetings/cmeet123"), DeepLinkMatch(tab: .more, route: .meetings(.notes(id: "cmeet123"))))
        XCTAssertEqual(resolve("/meetings"), DeepLinkMatch(tab: .more, route: .meetings(.home)))
        XCTAssertEqual(resolve("/meet/cmeet123"), DeepLinkMatch(tab: nil, route: .meetings(.call(id: "cmeet123"))))
        // The series page and odd ids stay on the web.
        XCTAssertNil(MeetingsRoute.deepLink(["meetings", "producers"], []))
        XCTAssertNil(MeetingsRoute.deepLink(["meetings", "a b"], []))
    }

    func testCatalogLinksNowResolveToNativeScreens() {
        let admin = PortalUser(email: "superadmin@example.edu", name: "Admin Example", role: .superAdmin, onStudentPackage: false)
        let links = PortalPagesCatalog.sections(for: admin, config: AppConfig.shared).flatMap(\.links)
        guard !links.isEmpty, let host = links.first?.url.host else { return } // no Portal configured in this build
        let base = URL(string: "https://\(host)")!
        for path in ["admin", "managers", "passwords", "settings"] {
            guard let link = links.first(where: { $0.url.path == "/\(path)" }) else { return XCTFail("missing \(path)") }
            XCTAssertNotNil(DeepLink.resolve(link.url, portal: base).route.flatMap { $0.isPortalPage ? nil : $0 }, path)
        }
    }
}
