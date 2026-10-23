import ApplicationServices
import XCTest
@testable import RuSwitcher

final class NativeSelectionAwaitTests: XCTestCase {
    @MainActor
    func testSameRangeExternalFieldChangeInvalidatesAwaitedSelection() throws {
        let field = ProductionCombinedShiftEditingTests.Field(pid: 5201,
            text: "ghbdtn MacSwitcher")
        field.caret = 0
        field.selection = "ghbdtn".utf16.count
        let converter = TextConverter(wholeFieldObservationOverride: { focus in
            guard focus.processID == field.pid,
                  CFEqual(focus.element, field.element) else { return nil }
            return field.observation
        })
        let focus = field.focus()
        let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: 4,
            currentInputRevision: { 4 })
        let before = try XCTUnwrap(converter.nativeSelectionBaseline(execution: execution))
        field.text = "ghbdtn OtherBrand" // same PID, element, range and selected text
        let after = try XCTUnwrap(converter.nativeSelectionBaseline(execution: execution))
        XCTAssertFalse(before.matches(after),
            "A new whole-field value cannot become the candidate's baseline after await")
        field.text = "ghbdtx OtherBrand" // selected bytes changed at the same range
        let changedSelection = try XCTUnwrap(converter.nativeSelectionBaseline(execution: execution))
        XCTAssertFalse(before.matches(changedSelection))
    }

    func testNewGestureCancelsOldSelectionTicketWithoutTypingRevisionChange() {
        var gate = NativeSelectionAwaitGate()
        let old = gate.nextAction()
        XCTAssertTrue(gate.permits(old, cancelled: false))
        let current = gate.nextAction() // another Shift, no character event
        XCTAssertFalse(gate.permits(old, cancelled: false))
        XCTAssertFalse(gate.permits(current, cancelled: true))
        XCTAssertTrue(gate.permits(current, cancelled: false))
    }
}
