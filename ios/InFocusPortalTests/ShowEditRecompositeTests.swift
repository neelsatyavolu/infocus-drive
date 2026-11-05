import XCTest
@testable import InFocusPortal

/// Editing's "Re-set the anchors on the virtual set" (Portal 53b72c2e, 3b74a90a, 81702504).
final class ShowEditRecompositeTests: XCTestCase {
    private func body(_ action: ShowEditAction) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? NSDictionary)
    }

    func testStartSendsRecompositeOnlyWhenTicked() throws {
        XCTAssertEqual(try body(.start(date: "2026-10-28", sources: [], note: nil, publish: nil, recomposite: true)),
                       ["action": "start", "date": "2026-10-28", "sources": [], "recomposite": true])
        XCTAssertEqual(try body(.start(date: "2026-10-28", sources: [], note: nil, publish: nil, recomposite: false)),
                       ["action": "start", "date": "2026-10-28", "sources": []])
    }

    func testRedoAlwaysSendsTheChoice() throws {
        XCTAssertEqual(try body(.redo(id: "job1", note: nil, recomposite: false)),
                       ["action": "redo", "id": "job1", "recomposite": false], "unticking it on Redo turns it off")
        XCTAssertEqual(try body(.redo(id: "job1", note: "Later take", recomposite: true)),
                       ["action": "redo", "id": "job1", "note": "Later take", "recomposite": true])
    }

    func testJobDecodesTheChoiceAndOlderPortalsWithout() throws {
        XCTAssertEqual(try ShowEditFixtures.review(date: "2026-10-28").job?.recomposite, false)
        let json = """
        {"id":"j","status":"REVIEW","stage":null,"message":null,"note":null,"publishAt":null,"decisions":[],"checks":null,
         "costUsd":null,"error":null,"cancelRequested":false,"pendingFix":null,"conversation":[],"version":1,"finishedAt":null}
        """
        XCTAssertNil(try PortalJSON.decoder().decode(ShowEditJob.self, from: Data(json.utf8)).recomposite)
        let used = json.replacingOccurrences(of: #""note":null,"#, with: #""note":null,"recomposite":true,"#)
        XCTAssertEqual(try PortalJSON.decoder().decode(ShowEditJob.self, from: Data(used.utf8)).recomposite, true)
    }

    func testLabelsMatchThePortal() {
        XCTAssertEqual(ShowEditRules.recompositeLabel, "Re-set the anchors on the virtual set (Experimental)")
        XCTAssertEqual(ShowEditRules.recompositeUsed, "Anchors re-set on the virtual set (experimental): check every shot before publishing.")
    }

    @MainActor
    func testRedoSendsTheTrimmedNoteAndChoice() async throws {
        let sent = Sent()
        let api = ShowEditAPI(state: { date in try ShowEditFixtures.review(date: date) },
                              send: { action in await sent.append(action) })
        let model = ShowEditModel(date: "2026-10-28", api: api)
        await model.load()
        let job = try XCTUnwrap(model.state.value?.job)
        let worked = await model.redo(job, note: "  ", recomposite: true)
        XCTAssertTrue(worked)
        let actions = await sent.actions
        XCTAssertEqual(actions, [.redo(id: "job1", note: nil, recomposite: true)])
        XCTAssertEqual(model.notice, "Starting the edit over.")
    }
}

private actor Sent {
    private(set) var actions: [ShowEditAction] = []
    func append(_ action: ShowEditAction) { actions.append(action) }
}
