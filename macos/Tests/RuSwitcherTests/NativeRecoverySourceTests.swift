import XCTest
@testable import RuSwitcher

final class NativeRecoverySourceTests: XCTestCase {
    func testRepeatedUncertaintyKeepsFirstWholeSourceRatherThanLatestAttempt() {
        let first = "😀 ghbdtn tail"
        XCTAssertEqual(NativeWholeFieldRecovery.originalText(prepared: "😀 при tail", replacedRange: 3..<6,
            preservedSource: first, preservedIsWholeField: true), first)
        XCTAssertEqual(NativeWholeFieldRecovery.originalText(prepared: "😀 g tail", replacedRange: 3..<4,
            preservedSource: first, preservedIsWholeField: true), first)
    }
    func testLegacyShortSourceIsMergedIntoWholePreparedFieldWithExactNeighbours() {
        let prepared = "😀 e\u{301} привет tail"
        let start = "😀 e\u{301} ".utf16.count
        let merged = NativeWholeFieldRecovery.originalText(prepared: prepared, replacedRange: start..<(start + 6),
            preservedSource: "ghbdtn", preservedIsWholeField: false)
        XCTAssertEqual(merged.map { Array($0.utf16) }, Array("😀 e\u{301} ghbdtn tail".utf16))
        XCTAssertEqual(NativeWholeFieldRecovery.originalText(prepared: prepared, replacedRange: start..<(start + 6)), prepared)
    }
    func testUnboundedOrSurrogateSplittingRecoveryRefusesBeforeAnotherWrite() {
        XCTAssertNil(NativeWholeFieldRecovery.originalText(prepared: "😀x", replacedRange: 1..<2,
            preservedSource: "a", preservedIsWholeField: false))
        XCTAssertNil(NativeWholeFieldRecovery.originalText(prepared: String(repeating: "a", count: 32768),
            replacedRange: 0..<1, preservedSource: "bb", preservedIsWholeField: false))
        XCTAssertNil(NativeWholeFieldRecovery.originalText(prepared: "a", replacedRange: 0..<1,
            preservedSource: String(repeating: "b", count: 32769), preservedIsWholeField: true))
    }
}
