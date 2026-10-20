import ApplicationServices
import XCTest
@testable import RuSwitcher

final class CombinedShiftExecutionTests: XCTestCase {
    func testNativeClipboardUndoRefusesEditedTextWhileLegacyFallbackRemains() {
        XCTAssertFalse(CombinedShiftExecutionPolicy.permitsClipboardUndo(copiedText: "edited", lastConverted: "привет", native: true))
        XCTAssertFalse(CombinedShiftExecutionPolicy.permitsClipboardUndo(copiedText: "", lastConverted: "", native: true))
        XCTAssertTrue(CombinedShiftExecutionPolicy.permitsClipboardUndo(copiedText: "привет", lastConverted: "привет", native: true))
        XCTAssertTrue(CombinedShiftExecutionPolicy.permitsClipboardUndo(copiedText: "edited", lastConverted: "привет", native: false))
    }
    func testNativeExecutionRefusesLateInputDifferentFieldMissingPIDAndSecureInput() {
        XCTAssertFalse(CombinedShiftExecutionPolicy.permits(originalPID: 10, currentPID: 10,
            expectedRevision: 1, currentRevision: 2, sameFocus: true, secureInput: false))
        XCTAssertFalse(CombinedShiftExecutionPolicy.permits(originalPID: 10, currentPID: 10,
            expectedRevision: 1, currentRevision: 1, sameFocus: false, secureInput: false))
        XCTAssertFalse(CombinedShiftExecutionPolicy.permits(originalPID: nil, currentPID: nil,
            expectedRevision: 1, currentRevision: 1, sameFocus: true, secureInput: false))
        XCTAssertFalse(CombinedShiftExecutionPolicy.permits(originalPID: 10, currentPID: 10,
            expectedRevision: 1, currentRevision: 1, sameFocus: true, secureInput: true))
        XCTAssertTrue(CombinedShiftExecutionPolicy.permits(originalPID: 10, currentPID: 10,
            expectedRevision: 1, currentRevision: 1, sameFocus: true, secureInput: false))
    }

    func testLastMomentWordAndCaretValidationRejectsNewCharacterEvenBeforeTapRevisionCatchesUp() {
        let before = CFRange(location: 6, length: 0)
        XCTAssertFalse(CombinedShiftExecutionPolicy.matchesBuffer(original: "ghbdtn", initialSelection: before,
            currentSelection: CFRange(location: 7, length: 0), observedSuffix: "hbdtnx"))
        XCTAssertFalse(CombinedShiftExecutionPolicy.matchesBuffer(original: "ghbdtn", initialSelection: before,
            currentSelection: before, observedSuffix: "hbdtnx"))
        XCTAssertFalse(CombinedShiftExecutionPolicy.matchesBuffer(original: "ghbdtn", initialSelection: before,
            currentSelection: CFRange(location: 5, length: 0), observedSuffix: "ghbdtn"))
        XCTAssertFalse(CombinedShiftExecutionPolicy.matchesBuffer(original: "ghbdtn", initialSelection: nil,
            currentSelection: before, observedSuffix: "ghbdtn"))
        XCTAssertTrue(CombinedShiftExecutionPolicy.matchesBuffer(original: "ghbdtn", initialSelection: before,
            currentSelection: before, observedSuffix: "ghbdtn"))
    }

    @MainActor
    func testRefusedNativeWordDoesNotReportSuccessOrCommitUndoHistory() throws {
        let layouts = LayoutSwitcher.installedLayouts()
        let en = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let ru = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        let direction = CombinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(en), targetLayoutID: LayoutSwitcher.sourceID(ru))
        // A nonexistent destination and stale revision must refuse before any events or history.
        let focus = CombinedShiftFocus(processID: Int32.max, element: AXUIElementCreateApplication(Int32.max))
        let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: 1, currentInputRevision: { 2 })
        let converter = TextConverter()
        let keys = [5, 4, 11, 2, 17, 45].map { TypedKey(keyCode: UInt16($0), shift: false, caps: false) }
        XCTAssertFalse(converter.convert(wordKeys: keys, prevWordKeys: [], boundaryCount: 0, context: direction, execution: execution))
        XCTAssertFalse(converter.hasReconversionState)
        XCTAssertNil(converter.lastResultLayoutID)
        let clipboardCount = NSPasteboard.general.changeCount
        XCTAssertFalse(converter.convertViaClipboard(wordLength: 0, prevWordLength: 0, boundaryCount: 0,
            context: direction, execution: execution))
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardCount)
        XCTAssertFalse(converter.convert(wordKeys: keys, prevWordKeys: [], boundaryCount: 0, context: direction))
        XCTAssertFalse(converter.hasReconversionState)
    }
}
