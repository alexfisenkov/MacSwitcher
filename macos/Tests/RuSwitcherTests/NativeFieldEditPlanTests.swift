import XCTest
@testable import RuSwitcher

final class NativeFieldEditPlanTests: XCTestCase {
    private func plan(_ text: String = "ghbd", caret: Int = 4, selection: Int = 0,
                      start: Int = 0, original: String = "ghbd", replacement: String = "прив",
                      editable: Bool = true) -> Result<NativeFieldEditPlan, NativeFieldEditRefusal> {
        NativeFieldEditPlan.make(original: original, replacement: replacement, start: start,
            snapshot: NativeFieldObservation(text: text, caretUTF16Location: caret, selectionLength: selection),
            isEditable: editable)
    }

    func testPlanPreservesExactUnicodeNeighboursAtNonzeroUTF16Start() throws {
        let prefix = "😀 e\u{301} "
        let suffix = " tail 🧑🏽‍💻"
        let start = prefix.utf16.count
        let value = try plan(prefix + "ghbd" + suffix, caret: start + 4, start: start).get()
        XCTAssertEqual(value.originalSnapshot.text.utf16.map { $0 }, Array((prefix + "ghbd" + suffix).utf16))
        XCTAssertEqual(value.resultSnapshot.text.utf16.map { $0 }, Array((prefix + "прив" + suffix).utf16))
        XCTAssertEqual(value.resultSnapshot.caretUTF16Location, start + 4)
        XCTAssertEqual(value.steps.count, 13)
        XCTAssertEqual(value.steps.first?.operation, .insertReplacement)
        XCTAssertEqual(value.steps.first?.expectedAfter.text, prefix + "ghbdприв" + suffix)
        for index in 1..<value.steps.count {
            XCTAssertEqual(value.steps[index].expectedBefore, value.steps[index - 1].expectedAfter)
        }
        XCTAssertEqual(value.steps.last?.expectedAfter, value.resultSnapshot)
    }

    func testEveryLeftDeleteAndRightHasAnExactWholeFieldState() throws {
        let value = try plan().get()
        XCTAssertEqual(value.steps.map(\.operation), [.insertReplacement]
            + Array(repeating: .left, count: 4) + Array(repeating: .backspace, count: 4)
            + Array(repeating: .right, count: 4))
        XCTAssertEqual(value.steps[4].expectedAfter, NativeFieldObservation(text: "ghbdприв", caretUTF16Location: 4, selectionLength: 0))
        XCTAssertEqual(value.steps[5].expectedAfter, NativeFieldObservation(text: "ghbприв", caretUTF16Location: 3, selectionLength: 0))
        XCTAssertEqual(value.steps[8].expectedAfter, NativeFieldObservation(text: "прив", caretUTF16Location: 0, selectionLength: 0))
        XCTAssertEqual(value.steps[9].expectedAfter, NativeFieldObservation(text: "прив", caretUTF16Location: 1, selectionLength: 0))
    }

    func testRejectsReadOnlyInvalidSelectionRangeTextAndUnsupportedEdits() {
        let failures = [plan(editable: false), plan(caret: 3), plan(selection: 1), plan(start: -1),
            plan(start: Int.max), plan("Ghbd"), plan(original: "", replacement: ""),
            plan(original: "ghbd", replacement: "привет"), plan(original: "ghbd", replacement: "ghbd"),
            plan(original: "😀", replacement: "ab"), plan(original: "e\u{301}", replacement: "ab")]
        for result in failures { if case .success = result { XCTFail("Unsafe plan was accepted") } }
    }

    func testRejectsRTLAndBidiControlsAnywhereIncludingSupplementaryScripts() {
        for neighbor in ["שלום", "مرحبا", "𞤀", "١٢٣", "\u{202E}", "\u{2067}", "\u{061C}", "\u{200F}"] {
            if case .success = plan("ghbd " + neighbor) { XCTFail("Accepted unsafe direction") }
            if case .success = plan(neighbor + " ghbd", caret: neighbor.utf16.count + 5,
                                    start: neighbor.utf16.count + 1) { XCTFail("Accepted unsafe prefix") }
        }
    }

    func testFieldBoundIncludesInsertFirstDuplicateAndEditLengthIsBounded() {
        let max = NativeFieldEditPlan.maximumFieldUnits
        XCTAssertNoThrow(try plan("ghbd" + String(repeating: "x", count: max - 8)).get())
        if case .success = plan("ghbd" + String(repeating: "x", count: max - 7)) { XCTFail("Duplicate exceeds whole-field bound") }
        let limit = NativeFieldEditPlan.maximumEditUnits
        XCTAssertEqual(limit, 24)
        let accepted = String(repeating: "a", count: limit)
        XCTAssertNoThrow(try plan(accepted, caret: limit, original: accepted,
                                 replacement: String(repeating: "б", count: limit)).get())
        let rejected = accepted + "a"
        if case .success = plan(rejected, caret: limit + 1, original: rejected,
                                replacement: String(repeating: "б", count: limit + 1)) { XCTFail("Long edit accepted") }
    }

    func testWholeObservationEqualityIsExactUTF16RatherThanCanonicalEquality() {
        let composed = NativeFieldObservation(text: "é", caretUTF16Location: 1, selectionLength: 0)
        let decomposed = NativeFieldObservation(text: "e\u{301}", caretUTF16Location: 1, selectionLength: 0)
        XCTAssertNotEqual(composed, decomposed)
    }

    func testRawUTF16ValidationRejectsUnpairedSurrogates() {
        XCTAssertTrue(NativeFieldEditPlan.isWellFormedUTF16([0x61, 0xD83D, 0xDE00]))
        XCTAssertFalse(NativeFieldEditPlan.isWellFormedUTF16([0xD800]))
        XCTAssertFalse(NativeFieldEditPlan.isWellFormedUTF16([0xDC00]))
        XCTAssertFalse(NativeFieldEditPlan.isWellFormedUTF16([0xD800, 0x61]))
    }
}
