import XCTest
@testable import RuSwitcher

final class GenericShellEditorReconciliationTests: XCTestCase {
    func testLostACKUsesReadOnlyStateWithoutResendingEdit() {
        let before = GenericShellEditorSnapshot(sessionPID: 10, tty: "/dev/ttys001",
            lineNonce: "D7607DCE-E311-498A-8305-D41E12E9CBA8.1", buffer: "ghbdtn",
            cursor: 6, mark: 0, regionActive: 0)
        let proposal = GenericShellEditorProposal(expected: before,
            replacementBuffer: "привет", replacementCursor: 6, requestID: UUID())
        XCTAssertEqual(GenericShellEditorReconciliation.classify(before: before,
            proposal: proposal, observed: nil), .unknown)
        XCTAssertEqual(GenericShellEditorReconciliation.classify(before: before,
            proposal: proposal, observed: before), .unchanged)
        let applied = GenericShellEditorSnapshot(sessionPID: 10, tty: before.tty,
            lineNonce: before.lineNonce, buffer: "привет", cursor: 6, mark: 0, regionActive: 0)
        XCTAssertEqual(GenericShellEditorReconciliation.classify(before: before,
            proposal: proposal, observed: applied), .confirmed)
        let different = GenericShellEditorSnapshot(sessionPID: 10, tty: before.tty,
            lineNonce: before.lineNonce, buffer: "привеt", cursor: 6, mark: 0, regionActive: 0)
        XCTAssertEqual(GenericShellEditorReconciliation.classify(before: before,
            proposal: proposal, observed: different), .unknown)
        let nextLine = GenericShellEditorSnapshot(sessionPID: 10, tty: before.tty,
            lineNonce: "D7607DCE-E311-498A-8305-D41E12E9CBA8.2", buffer: "привет",
            cursor: 6, mark: 0, regionActive: 0)
        XCTAssertEqual(GenericShellEditorReconciliation.classify(before: before,
            proposal: proposal, observed: nextLine), .unknown)
    }
}
