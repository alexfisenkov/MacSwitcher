import XCTest
@testable import RuSwitcher

final class GenericShellEditorPlannerTests: XCTestCase {
    private func snapshot(_ buffer: String, cursor: Int, mark: Int = 0,
                          region: Int = 0) -> GenericShellEditorSnapshot {
        GenericShellEditorSnapshot(sessionPID: 1, tty: "/dev/ttys001",
            lineNonce: "D7607DCE-E311-498A-8305-D41E12E9CBA8.1",
            buffer: buffer, cursor: cursor, mark: mark, regionActive: region)
    }

    func testExactWordAndTrailingSpacesPreserveOtherCommandText() {
        let before = snapshot("echo 'ghbdtn'  ", cursor: 15)
        let range = GenericShellEditorPlanner.exactWordRange(before, word: "ghbdtn",
            trailingSpaces: 0, externalSelection: .collapsed)
        XCTAssertNil(range) // quote and spaces are not a word immediately before caret
        let simple = snapshot("echo ghbdtn  ", cursor: 13)
        let word = GenericShellEditorPlanner.exactWordRange(simple, word: "ghbdtn",
            trailingSpaces: 2, externalSelection: .collapsed)
        XCTAssertEqual(word, 5..<11)
        let proposal = GenericShellEditorPlanner.proposal(snapshot: simple, range: word!,
            replacement: "привет")
        XCTAssertEqual(proposal?.replacementBuffer, "echo привет  ")
        XCTAssertEqual(proposal?.replacementCursor, 13)
        XCTAssertEqual(proposal?.replacementBuffer.prefix(proposal!.replacementCursor), "echo привет  ")
        let longer = GenericShellEditorPlanner.proposal(snapshot: simple, range: word!,
            replacement: "приветик")
        XCTAssertEqual(longer?.replacementCursor, 15)
        XCTAssertEqual(longer?.replacementBuffer, "echo приветик  ")
        let midline = snapshot("echo ghbdtn  ;", cursor: 13)
        let midWord = GenericShellEditorPlanner.exactWordRange(midline, word: "ghbdtn",
            trailingSpaces: 2, externalSelection: .collapsed)!
        let midProposal = GenericShellEditorPlanner.proposal(snapshot: midline,
            range: midWord, replacement: "привет")!
        var continued = Array(midProposal.replacementBuffer.unicodeScalars)
        continued.insert("x", at: midProposal.replacementCursor)
        XCTAssertEqual(String(String.UnicodeScalarView(continued)), "echo привет  x;")
    }

    func testSelectedRegionAndOutputSelectionRefuse() {
        let active = snapshot("ghbdtn suffix", cursor: 6, mark: 0, region: 1)
        XCTAssertEqual(GenericShellEditorPlanner.selectedRange(active,
            externalSelection: .collapsed), 0..<6)
        XCTAssertNil(GenericShellEditorPlanner.selectedRange(active,
            externalSelection: .selected))
        XCTAssertNil(GenericShellEditorPlanner.exactWordRange(active, word: "ghbdtn",
            trailingSpaces: 0, externalSelection: .collapsed))
        XCTAssertNil(GenericShellEditorPlanner.wholePrefixRange(active, externalSelection: .unknown))
    }

    func testUnicodeScalarOffsetsDoNotUseGraphemeCount() {
        let before = snapshot("👩‍💻 ghbdtn", cursor: 10)
        XCTAssertEqual(before.buffer.count, 8)
        XCTAssertEqual(before.buffer.unicodeScalars.count, 10)
        let range = GenericShellEditorPlanner.exactWordRange(before, word: "ghbdtn",
            trailingSpaces: 0, externalSelection: .collapsed)
        XCTAssertEqual(range, 4..<10)
        XCTAssertEqual(GenericShellEditorPlanner.proposal(snapshot: before, range: range!,
            replacement: "привет")?.replacementBuffer, "👩‍💻 привет")
    }

    func testObservedLastWordIsBoundedAndOutputSelectionBlocksFallback() {
        let line = snapshot("echo ghbdtn  ", cursor: 13)
        XCTAssertEqual(GenericShellEditorPlanner.observedLastWordRange(line,
            externalSelection: .collapsed), 5..<11)
        XCTAssertNil(GenericShellEditorPlanner.observedLastWordRange(line,
            externalSelection: .selected))
        XCTAssertNil(GenericShellEditorPlanner.observedLastWordRange(
            snapshot("echo ghbdtn;", cursor: 12), externalSelection: .collapsed))
        XCTAssertNil(GenericShellEditorPlanner.observedLastWordRange(
            snapshot(String(repeating: "a", count: 25), cursor: 25), externalSelection: .collapsed))
    }
}
