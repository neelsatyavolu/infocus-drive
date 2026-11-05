import XCTest
@testable import InFocusPortal

/// Settings → Birthday (`PATCH api/profile`) and the More labels that follow the web sidebar.
final class ProfileBirthdayTests: XCTestCase {
    private func service() -> SettingsService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return SettingsService(client: PortalClient(portal: URL(string: "https://portal.example.edu")!,
                                                    session: URLSession(configuration: config), cookies: { [] }))
    }

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.lastRequest = nil
    }

    private func sentBody() throws -> [String: Any] {
        let data = try XCTUnwrap(StubProtocol.lastRequest?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDecodesBirthdayAndOlderProfiles() throws {
        let profile = try AdminFixtures.decode(ProfileInfo.self,
            #"{"data":{"email":"abby@example.edu","name":"Abby Example","nickname":null,"birthdayMonth":2,"birthdayDay":29,"sampleOnly":false}}"#)
        XCTAssertEqual(Birthday.saved(profile), Birthday(month: 2, day: 29))
        let older = try AdminFixtures.decode(ProfileInfo.self, #"{"data":{"email":"otto@example.edu","name":"Otto","nickname":"O"}}"#)
        XCTAssertNil(older.birthdayMonth)
        XCTAssertNil(Birthday.saved(older))
    }

    func testDaysAndDrafts() {
        XCTAssertEqual(Birthday.days(inMonth: 2), 29, "February allows the 29th")
        XCTAssertEqual(Birthday.days(inMonth: 4), 30)
        XCTAssertEqual(Birthday.days(inMonth: 0), 31, "no month picked")
        XCTAssertEqual(Birthday.day(31, keptFor: 2), 0, "no February 31")
        XCTAssertEqual(Birthday.day(15, keptFor: 2), 15)
        XCTAssertEqual(Birthday.draft(month: 0, day: 0), .clear)
        XCTAssertEqual(Birthday.draft(month: 3, day: 0), .incomplete)
        XCTAssertEqual(Birthday.draft(month: 0, day: 12), .incomplete)
        XCTAssertEqual(Birthday.draft(month: 4, day: 31), .incomplete)
        XCTAssertEqual(Birthday.draft(month: 11, day: 8), .set(Birthday(month: 11, day: 8)))
    }

    func testSaveAndRemoveSendOnlyTheBirthday() async throws {
        StubProtocol.handler = { _ in
            (200, Data(#"{"data":{"email":"sage@example.edu","name":"Sage","nickname":null,"birthdayMonth":11,"birthdayDay":8}}"#.utf8))
        }
        let saved = try await service().saveBirthday(Birthday(month: 11, day: 8))
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/profile")
        var body = try sentBody()
        XCTAssertEqual(body.keys.sorted(), ["birthday"], "a missing nickname keeps it")
        XCTAssertEqual(body["birthday"] as? [String: Int], ["month": 11, "day": 8])
        XCTAssertEqual(saved.birthdayDay, 8)

        _ = try await service().saveBirthday(nil)
        body = try sentBody()
        XCTAssertTrue(body["birthday"] is NSNull, "null removes it; leaving it out would keep it")
    }
}

final class MoreLabelsTests: XCTestCase {
    func testPortalPagesFollowTheSidebar() {
        let links = PortalPagesCatalog.sections(for: .stub("associate"), config: AppConfig.shared).flatMap(\.links)
        let titles = links.map(\.title)
        XCTAssertTrue(titles.contains("People"))
        XCTAssertFalse(titles.contains("Members"))
        XCTAssertFalse(titles.contains("Participation"), "Participation is in the Grade Editor, for executives")
    }
}
