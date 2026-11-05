import XCTest
@testable import InFocusPortal

/// Hand-picked anchors who already anchored this month (Portal 8d0f63b5) and the crew roles
/// without Graphics Director (8a75ca63, 48ccfcf7). Fictional data only.
final class HandPickedAnchorTests: XCTestCase {
    func testOnlyTheOtherSlotIsBlocked() {
        XCTAssertEqual(CastEligibility.pairBlock("sage", otherSlot: "Sage"), .otherSlot)
        XCTAssertNil(CastEligibility.pairBlock("Abby", otherSlot: "Sage"),
                     "someone who anchored earlier this month can still be picked by hand; only Randomize skips them")
        XCTAssertNil(CastEligibility.pairBlock("Abby", otherSlot: ""))
    }

    func testStubCrewMatchesThePortalRoles() {
        let show = CalendarStubData.overview("2026-10-07")
        XCTAssertEqual(show.roles, ["Show Director", "Tech Director", "Teleprompter", "Floor Director"])
        XCTAssertFalse(show.assignments.keys.contains("Graphics Director"))
    }
}
