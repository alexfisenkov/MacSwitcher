import ApplicationServices
import XCTest
@testable import RuSwitcher

final class PredictionRuntimeTests: XCTestCase {
    func testContextRetainsAmbiguousTokenAcrossSourceChangeAndLiteralSpaces() throws {
        var buffer = PredictionInputBuffer()
        buffer.append("я думаю f", processID: 123)
        buffer.append("  привет", processID: 123)
        let snapshot = try XCTUnwrap(buffer.snapshot(sourceLayoutID: "ru", inputRevision: 9, generation: 11))
        XCTAssertEqual(snapshot.suffix, "f  привет")
        XCTAssertEqual(snapshot.precedingWords, ["я", "думаю"])
        XCTAssertEqual(snapshot.sourceLayoutID, "ru")
        XCTAssertFalse(snapshot.atBoundary)
        XCTAssertTrue(buffer.replaceSuffix(original: "f  привет", replacement: "а  привет"))
        XCTAssertEqual(buffer.text, "я думаю а  привет")
    }

    func testSnapshotIncludesBoundaryAndRejectsEveryStaleExecutionIdentity() throws {
        var buffer = PredictionInputBuffer()
        buffer.append("ghbdtn ", processID: 123)
        let snapshot = try XCTUnwrap(buffer.snapshot(sourceLayoutID: "en", inputRevision: 10, generation: 20))
        XCTAssertEqual(snapshot.suffix, "ghbdtn ")
        XCTAssertTrue(snapshot.atBoundary)
        XCTAssertTrue(snapshot.isCurrent(processID: 123, revision: 10, generation: 20))
        XCTAssertFalse(snapshot.isCurrent(processID: 123, revision: 11, generation: 20))
        XCTAssertFalse(snapshot.isCurrent(processID: 123, revision: 10, generation: 21))
        XCTAssertFalse(snapshot.isCurrent(processID: 124, revision: 10, generation: 20))
        XCTAssertFalse(snapshot.isCurrent(processID: nil, revision: 10, generation: 20))
    }

    func testFocusChangeNavigationAndInvalidPayloadCannotCarryPreviousWord() throws {
        var buffer = PredictionInputBuffer()
        buffer.append("f ", processID: 123)
        let oldSession = buffer.sessionID
        buffer.append("привет", processID: 124)
        XCTAssertEqual(buffer.text, "привет")
        XCTAssertNotEqual(buffer.sessionID, oldSession)
        buffer.reset() // same reset used by click, navigation, shortcuts and paste
        XCTAssertNil(buffer.snapshot(sourceLayoutID: "en", inputRevision: 0, generation: 0))
        buffer.append("secret", processID: 124)
        buffer.append("\n", processID: 124)
        XCTAssertEqual(buffer.text, "")
        XCTAssertNil(buffer.processID)
    }

    func testUnknownOriginalFieldOrSamePIDFieldReplacementCannotBecomeLateAnchor() {
        XCTAssertTrue(PredictionFocusAnchorPolicy.permits(originalSession: 4, currentSession: 4,
            capturedOriginalField: true, sameField: true))
        XCTAssertFalse(PredictionFocusAnchorPolicy.permits(originalSession: 4, currentSession: 4,
            capturedOriginalField: true, sameField: false))
        XCTAssertFalse(PredictionFocusAnchorPolicy.permits(originalSession: 4, currentSession: 4,
            capturedOriginalField: false, sameField: true))
        XCTAssertFalse(PredictionFocusAnchorPolicy.permits(originalSession: 4, currentSession: 5,
            capturedOriginalField: true, sameField: true))
        XCTAssertFalse(PredictionFocusAnchorPolicy.permits(originalSession: nil, currentSession: 4,
            capturedOriginalField: true, sameField: true))
    }

    func testUnchangedEmojiAndBrandAreExcludedFromTheActualSuffixEdit() throws {
        let edit = try XCTUnwrap(PredictionSuffixEdit(original: "👨‍👩‍👧‍👦 ghbdtn ", replacement: "👨‍👩‍👧‍👦 привет "))
        XCTAssertEqual(edit.original, "ghbdtn ")
        XCTAssertEqual(edit.replacement, "привет ")
        let context = try XCTUnwrap(PredictionSuffixEdit(original: "f привет", replacement: "а привет"))
        XCTAssertEqual(context.original, "f привет")
        XCTAssertEqual(context.replacement, "а привет")
        XCTAssertNil(PredictionSuffixEdit(original: "MacSwitcher", replacement: "MacSwitcher"))
    }

    func testEventLinkedCaretRejectsJumpToIdenticalSuffixInSameField() {
        let anchor = PredictionCaretAnchor(caretUTF16Location: 101, inputUTF16Offset: 1)
        XCTAssertTrue(anchor.permits(location: 106, selectionLength: 0, cumulativeOffset: 6))
        // The text can be identical at another occurrence; its caret still differs.
        XCTAssertFalse(anchor.permits(location: 506, selectionLength: 0, cumulativeOffset: 6))
        XCTAssertFalse(anchor.permits(location: 106, selectionLength: 2, cumulativeOffset: 6))
        let overflow = PredictionCaretAnchor(caretUTF16Location: Int.max, inputUTF16Offset: 0)
        XCTAssertNil(overflow.expectedLocation(for: 1))
    }

    func testCumulativeCaretOffsetSurvivesWindowTruncationAndAdjustsForUnicodeEdit() {
        var buffer = PredictionInputBuffer()
        for _ in 0..<100 { buffer.append("word ", processID: 123) }
        XCTAssertLessThanOrEqual(buffer.text.count, PredictionInputBuffer.maximumCharacters)
        XCTAssertEqual(buffer.cumulativeUTF16Offset, 500)
        buffer.append("f привет", processID: 123)
        XCTAssertEqual(buffer.cumulativeUTF16Offset, 508)
        XCTAssertTrue(buffer.replaceSuffix(original: "f привет", replacement: "😀 привет"))
        XCTAssertEqual(buffer.cumulativeUTF16Offset, 509) // emoji occupies two UTF16 units
        let anchor = PredictionCaretAnchor(caretUTF16Location: 11, inputUTF16Offset: 1)
        XCTAssertEqual(anchor.expectedLocation(for: buffer.cumulativeUTF16Offset), 519)
        buffer.reset()
        XCTAssertEqual(buffer.cumulativeUTF16Offset, 0)
    }

    func testWindowIsBoundedAndSuffixReplacementMustMatchExactly() throws {
        var buffer = PredictionInputBuffer()
        for _ in 0..<100 { buffer.append("someword ", processID: 123) }
        XCTAssertLessThanOrEqual(buffer.text.count, PredictionInputBuffer.maximumCharacters)
        let snapshot = try XCTUnwrap(buffer.snapshot(sourceLayoutID: "en", inputRevision: 1, generation: 1))
        XCTAssertEqual(snapshot.suffix, "someword someword ")
        XCTAssertLessThanOrEqual(snapshot.precedingWords.count, 4)
        XCTAssertFalse(buffer.replaceSuffix(original: "wrong", replacement: "а"))
        XCTAssertTrue(buffer.text.hasSuffix("someword "))
        buffer.reset()
        buffer.append(String(repeating: "x", count: 1000), processID: 123)
        XCTAssertEqual(buffer.text, "")
    }

    func testCombiningMarksCannotGrowOneGraphemeBeyondUTF16Budget() {
        var buffer = PredictionInputBuffer()
        buffer.append("a", processID: 123)
        for _ in 0..<100 { buffer.append(String(repeating: "\u{301}", count: 8), processID: 123) }
        XCTAssertLessThanOrEqual(buffer.text.utf16.count, 384)
        XCTAssertNil(buffer.snapshot(sourceLayoutID: "en", inputRevision: 1, generation: 1))
        buffer.append(" ", processID: 123)
        buffer.append("normal", processID: 123)
        XCTAssertEqual(buffer.snapshot(sourceLayoutID: "en", inputRevision: 2, generation: 2)?.suffix, "normal")
    }

    func testSeededUnicodeAndBoundaryStreamKeepsPredictionWindowBounded() {
        var buffer = PredictionInputBuffer()
        var seed: UInt64 = 0xA11CE5EED
        let fragments = ["a", " ", "😀", "e\u{301}", String(repeating: "\u{301}", count: 8)]
        for index in 0..<5_000 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            buffer.append(fragments[Int(seed % UInt64(fragments.count))], processID: index < 2_500 ? 123 : 124)
            XCTAssertLessThanOrEqual(buffer.text.utf16.count, 384, "seeded event \(index)")
            if let snapshot = buffer.snapshot(sourceLayoutID: "en", inputRevision: UInt64(index), generation: 1) {
                XCTAssertLessThanOrEqual(snapshot.suffix.utf16.count, 192)
                XCTAssertEqual(snapshot.processID, index < 2_500 ? 123 : 124)
            }
        }
    }

    @MainActor
    func testAutomaticWriterRefusesStaleFieldBeforeCommittingUndoState() {
        let converter = TextConverter()
        let focus = CombinedShiftFocus(processID: Int32.max, element: AXUIElementCreateApplication(Int32.max))
        let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: 1, currentInputRevision: { 2 })
        XCTAssertFalse(converter.replaceVerifiedSuffix(original: "f привет", replacement: "а привет",
            sourceLayoutID: "ru", resultLayoutID: "ru", execution: execution))
        XCTAssertFalse(converter.hasReconversionState)
        XCTAssertNil(converter.lastResultLayoutID)
        XCTAssertFalse(converter.replaceVerifiedSuffix(original: "f", replacement: "f",
            sourceLayoutID: "en", resultLayoutID: "ru", execution: execution))
    }
}
