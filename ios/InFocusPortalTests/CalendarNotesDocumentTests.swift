import XCTest
@testable import InFocusPortal

/// Master Calendar notes edited on the phone keep everything the Portal's rich editor wrote.
/// Fictional data only.
final class CalendarNotesDocumentTests: XCTestCase {
    private let pill = "<span class=\"package-pill\" data-package-id=\"m1\" data-display-label=\"Club Fair\">Club Fair</span>"

    private var richCell: String {
        "<p><strong>No School</strong></p>"
            + "<p>Assembly in the gym</p><p><br></p><p>Bring &amp; share</p>\n"
            + "<ul><li><em>Rally</em> at <u>noon</u></li><li><b>Spirit</b> day</li></ul>"
            + "<p>Air " + pill + " <i>today</i></p>"
            + "<p>" + pill.replacingOccurrences(of: "m1", with: "m2") + "</p>"
    }

    func testRichNoteRoundTripsUnchanged() {
        for html in [richCell, "", "<p>Plain</p>", "<p><strong>Only bold</strong></p>", "loose <b>text</b> outside a paragraph",
                     "<p>Unbalanced <strong>bold</p>", "</p>stray close", "  <p>a</p>  <p>b</p>  "] {
            let doc = CalendarNotesDocument.parse(html)
            XCTAssertEqual(doc.body(), html.trimmingCharacters(in: .whitespacesAndNewlines), "round trip: \(html)")
            XCTAssertFalse(doc.isDirty)
        }
    }

    func testImageTokenIsLeftToTheEditor() {
        let doc = CalendarNotesDocument.parse("[[NO_MONDAY_IMAGE]]<p><em>Hi</em></p>")
        XCTAssertEqual(doc.body(), "<p><em>Hi</em></p>")
    }

    func testSplitsTextRunsRichBlocksAndPills() {
        let doc = CalendarNotesDocument.parse(richCell)
        XCTAssertEqual(doc.blocks.count, 5)
        guard case .rich("<p><strong>No School</strong></p>") = doc.blocks[0] else { return XCTFail("\(doc.blocks[0])") }
        XCTAssertEqual(doc.text(at: 1), "Assembly in the gym\n\nBring & share")
        guard case .rich = doc.blocks[2], case .rich = doc.blocks[3], case .pill(let p, _) = doc.blocks[4] else {
            return XCTFail("\(doc.blocks)")
        }
        XCTAssertEqual(p.id, "m2")
        XCTAssertTrue(doc.hasFormatting)
        XCTAssertEqual(doc.pills.map(\.id), ["m1", "m2"], "pills inside formatted text are listed too")
    }

    func testEditingTextChangesOnlyThatRun() {
        var doc = CalendarNotesDocument.parse(richCell)
        doc.setText("Assembly <moved>\n\nBring & share", at: 1)
        XCTAssertTrue(doc.isDirty)
        let expected = richCell.replacingOccurrences(
            of: "<p>Assembly in the gym</p><p><br></p><p>Bring &amp; share</p>\n",
            with: "<p>Assembly &lt;moved&gt;</p><p><br></p><p>Bring &amp; share</p>")
        XCTAssertEqual(doc.body(), expected)
        XCTAssertTrue(doc.body().contains("<ul><li><em>Rally</em> at <u>noon</u></li><li><b>Spirit</b> day</li></ul>"))
    }

    func testEditingBackToTheOriginalIsNotDirty() {
        var doc = CalendarNotesDocument.parse(richCell)
        doc.setText("x", at: 1)
        doc.setText("Assembly in the gym\n\nBring & share", at: 1)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(doc.body(), richCell)
    }

    func testFormattedOnlyCellGetsAnEmptyTextRunToTypeIn() {
        var doc = CalendarNotesDocument.parse("<p><strong>No School</strong></p>")
        XCTAssertEqual(doc.blocks.count, 2)
        XCTAssertFalse(doc.isDirty, "the empty run writes nothing")
        doc.setText("Teacher work day", at: 1)
        XCTAssertEqual(doc.body(), "<p><strong>No School</strong></p><p>Teacher work day</p>")
    }

    func testPillEditsKeepFormatting() {
        var doc = CalendarNotesDocument.parse(richCell)
        doc.renamePill(id: "m1", label: "Fair")
        XCTAssertTrue(doc.body().contains("<p>Air <span class=\"package-pill\" data-package-id=\"m1\" data-display-label=\"Fair\">Fair</span> <i>today</i></p>"))
        doc.removePill(id: "m2")
        doc.removePill(id: "m1")
        XCTAssertEqual(doc.pills, [])
        XCTAssertTrue(doc.body().hasPrefix("<p><strong>No School</strong></p>"))
        XCTAssertTrue(doc.body().contains("<p>Air  <i>today</i></p>"))
        doc.addPill(id: "m3", label: "Gas & Prices")
        XCTAssertTrue(doc.body().hasSuffix("<p>" + CalendarNotes.pillHTML(id: "m3", label: "Gas & Prices") + "</p>"))
        doc.addPill(id: "m3", label: "Again")
        XCTAssertEqual(doc.pills.count, 1, "no duplicates")
    }

    func testRichTextRendersFormatting() {
        let text = CalendarRichText.attributed("<p><strong>No School</strong></p><ol><li>Rally</li><li>Lunch &amp; <em>games</em></li></ol>"
            + "<p>Air " + pill + "</p>")
        XCTAssertEqual(String(text.characters), "No School\n1. Rally\n2. Lunch & games\nAir Club Fair")
        let bold = text.runs.first { String(text[$0.range].characters) == "No School" }
        XCTAssertEqual(bold?.inlinePresentationIntent, .stronglyEmphasized)
        let italic = text.runs.first { String(text[$0.range].characters) == "games" }
        XCTAssertEqual(italic?.inlinePresentationIntent, .emphasized)
    }
}
