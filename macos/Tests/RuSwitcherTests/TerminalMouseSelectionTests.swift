import ApplicationServices
import XCTest
@testable import RuSwitcher

final class TerminalMouseSelectionTests: XCTestCase {
    private final class Fixture {
        let element = AXUIElementCreateApplication(301)
        let window = AXUIElementCreateApplication(302)
        let otherWindow = AXUIElementCreateApplication(303)
        var buffer: String
        var count: Int
        var selected: CFRange
        var secure: Bool? = false
        var displayedTail: String?
        var wrapped = false
        var missingBounds = false
        var clock: TimeInterval = 0
        var numberReads = 0
        var selectionReads = 0
        var tailReads = 0
        var changeCountAfterFirstRead = false
        var changeSelectionAfterFirstRead = false
        var missingNumber = false
        var currentWindowIsDifferent = false

        init(_ buffer: String, selectedUTF16: Range<Int>, count: Int = 100) {
            self.buffer = buffer
            self.count = count
            let start = count - buffer.utf16.count
            selected = CFRange(location: start + selectedUTF16.lowerBound,
                               length: selectedUTF16.count)
        }

        var focus: CombinedShiftFocus {
            CombinedShiftFocus(processID: 301, element: element, initialSelection: selected)
        }

        func reader() -> TerminalMouseSelection.Reader {
            TerminalMouseSelection.Reader(now: { self.clock },
                window: { _, budget in
                    guard budget.timeout() != nil else { return nil }
                    return self.currentWindowIsDifferent ? self.otherWindow : self.window
                }, secure: { _, budget in
                    guard budget.timeout() != nil else { return nil }
                    return self.secure
                }, numberOfCharacters: { _, budget in
                    guard budget.timeout() != nil, !self.missingNumber else { return nil }
                    self.numberReads += 1
                    return self.count + (self.changeCountAfterFirstRead && self.numberReads > 1 ? 1 : 0)
                }, selection: { _, budget in
                    guard budget.timeout() != nil else { return nil }
                    self.selectionReads += 1
                    if self.changeSelectionAfterFirstRead && self.selectionReads > 1 {
                        return CFRange(location: self.selected.location + 1,
                                       length: self.selected.length)
                    }
                    return self.selected
                }, stringForRange: { _, range, budget in
                    guard budget.timeout() != nil else { return nil }
                    let start = self.count - self.buffer.utf16.count
                    if range.location == start && range.length == self.buffer.utf16.count {
                        self.tailReads += 1
                        return self.displayedTail ?? self.buffer
                    }
                    guard range.location >= start, range.location + range.length <= self.count else {
                        return "output"
                    }
                    let units = Array(self.buffer.utf16)
                    let lower = range.location - start
                    return String(decoding: units[lower..<(lower + range.length)], as: UTF16.self)
                }, boundsForRange: { _, range, budget in
                    guard budget.timeout() != nil, !self.missingBounds else { return nil }
                    let y: CGFloat = self.wrapped && range.location + range.length == self.count ? 20 : 0
                    return CGRect(x: 0, y: y, width: 10, height: 16)
                })
        }
    }

    func testSelectedPartialWordMapsToScalarRangeAndRechecks() {
        let fixture = Fixture("echo ghbdtn suffix", selectedUTF16: 6..<9)
        let proof = TerminalMouseSelection.capture(focus: fixture.focus,
            expectedBuffer: fixture.buffer, reader: fixture.reader())
        XCTAssertEqual(proof?.scalarRange, 6..<9)
        XCTAssertTrue(proof?.isCurrent() == true)
        fixture.currentWindowIsDifferent = true
        XCTAssertFalse(proof?.isCurrent() ?? true)
        fixture.currentWindowIsDifferent = false
        fixture.displayedTail = "changed output tail"
        XCTAssertFalse(proof?.isCurrent() ?? true)
    }

    func testEmojiAndCombiningOffsetsRejectBrokenBoundaries() {
        let emoji = Fixture("👩‍💻 ghbdtn", selectedUTF16: 6..<12)
        XCTAssertEqual(TerminalMouseSelection.capture(focus: emoji.focus,
            expectedBuffer: emoji.buffer, reader: emoji.reader())?.scalarRange, 4..<10)
        let surrogate = Fixture("👩‍💻 ghbdtn", selectedUTF16: 1..<2)
        XCTAssertNil(TerminalMouseSelection.capture(focus: surrogate.focus,
            expectedBuffer: surrogate.buffer, reader: surrogate.reader()))
        let combining = Fixture("e\u{301} ghbd", selectedUTF16: 0..<2)
        XCTAssertEqual(TerminalMouseSelection.capture(focus: combining.focus,
            expectedBuffer: combining.buffer, reader: combining.reader())?.scalarRange, 0..<2)
        let splitCombining = Fixture("e\u{301} ghbd", selectedUTF16: 1..<2)
        XCTAssertNil(TerminalMouseSelection.capture(focus: splitCombining.focus,
            expectedBuffer: splitCombining.buffer, reader: splitCombining.reader()))
    }

    func testOutputSelectionWrongTailAndWrappedLineRefuse() {
        let output = Fixture("ghbdtn", selectedUTF16: -12..<(-6))
        XCTAssertNil(TerminalMouseSelection.capture(focus: output.focus,
            expectedBuffer: output.buffer, reader: output.reader()))
        let wrongTail = Fixture("ghbdtn", selectedUTF16: 0..<6)
        wrongTail.displayedTail = "history"
        XCTAssertNil(TerminalMouseSelection.capture(focus: wrongTail.focus,
            expectedBuffer: wrongTail.buffer, reader: wrongTail.reader()))
        let wrapped = Fixture("ghbdtn", selectedUTF16: 0..<6)
        wrapped.wrapped = true
        XCTAssertNil(TerminalMouseSelection.capture(focus: wrapped.focus,
            expectedBuffer: wrapped.buffer, reader: wrapped.reader()))
        let noBounds = Fixture("ghbdtn", selectedUTF16: 0..<6)
        noBounds.missingBounds = true
        XCTAssertNil(TerminalMouseSelection.capture(focus: noBounds.focus,
            expectedBuffer: noBounds.buffer, reader: noBounds.reader()))
    }

    func testChangedCountSelectionAndUnsupportedMetadataRefuse() {
        let count = Fixture("ghbdtn", selectedUTF16: 0..<6)
        count.changeCountAfterFirstRead = true
        XCTAssertNil(TerminalMouseSelection.capture(focus: count.focus,
            expectedBuffer: count.buffer, reader: count.reader()))
        let selection = Fixture("ghbdtn", selectedUTF16: 0..<6)
        selection.changeSelectionAfterFirstRead = true
        XCTAssertNil(TerminalMouseSelection.capture(focus: selection.focus,
            expectedBuffer: selection.buffer, reader: selection.reader()))
        let unavailable = Fixture("ghbdtn", selectedUTF16: 0..<6)
        unavailable.missingNumber = true
        XCTAssertNil(TerminalMouseSelection.capture(focus: unavailable.focus,
            expectedBuffer: unavailable.buffer, reader: unavailable.reader()))
        let secure = Fixture("ghbdtn", selectedUTF16: 0..<6)
        secure.secure = true
        XCTAssertNil(TerminalMouseSelection.capture(focus: secure.focus,
            expectedBuffer: secure.buffer, reader: secure.reader()))
    }

    func testMultilineOverlimitAndExpiredBudgetRefuseBeforeTailRead() {
        for buffer in ["one\ntwo", "one\rtwo", "one\0two", String(repeating: "x", count: 4_097)] {
            let fixture = Fixture(buffer, selectedUTF16: 0..<1, count: 5_000)
            XCTAssertNil(TerminalMouseSelection.capture(focus: fixture.focus,
                expectedBuffer: fixture.buffer, reader: fixture.reader()))
            XCTAssertEqual(fixture.tailReads, 0)
        }
        let late = Fixture("ghbdtn", selectedUTF16: 0..<6)
        let base = late.reader()
        let reader = TerminalMouseSelection.Reader(now: base.now, window: { focus, budget in
            let value = base.window(focus, budget)
            late.clock = 0.121
            return value
        }, secure: base.secure, numberOfCharacters: base.numberOfCharacters,
            selection: base.selection, stringForRange: base.stringForRange,
            boundsForRange: base.boundsForRange)
        XCTAssertNil(TerminalMouseSelection.capture(focus: late.focus,
            expectedBuffer: late.buffer, reader: reader))
        XCTAssertEqual(late.tailReads, 0)
    }
}
