import AppKit
import XCTest
@testable import RuSwitcher

final class ShellStartupRetryPolicyTests: XCTestCase {
    func testTransientRetryIsBoundedAndBackedOff() {
        var policy = ShellStartupRetryPolicy()
        policy.failed(.transient, now: 100)
        XCTAssertFalse(policy.claimRetry(now: 129.99, safe: true))
        XCTAssertFalse(policy.claimRetry(now: 130, safe: false))
        XCTAssertTrue(policy.claimRetry(now: 130, safe: true))
        policy.failed(.transient, now: 130)
        XCTAssertFalse(policy.claimRetry(now: 159, safe: true))
        XCTAssertTrue(policy.claimRetry(now: 160, safe: true))
        policy.failed(.transient, now: 160)
        XCTAssertTrue(policy.claimRetry(now: 190, safe: true))
        policy.failed(.transient, now: 190)
        XCTAssertFalse(policy.claimRetry(now: 999, safe: true))
        XCTAssertEqual(policy.retryCount, 3)
    }

    func testUnsafeFaultNeverAutomaticallyRetries() {
        var policy = ShellStartupRetryPolicy()
        policy.failed(.needsUserAction, now: 0)
        XCTAssertFalse(policy.claimRetry(now: 999, safe: true))
        policy.disabled()
        XCTAssertNil(policy.fault)
        XCTAssertEqual(policy.retryCount, 0)
    }
}

final class ManualShellCoordinatorPolicyTests: XCTestCase {
    @MainActor
    private func layoutPair() throws -> CombinedShiftContext {
        let layouts = LayoutSwitcher.installedLayouts()
        let en = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let ru = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        return CombinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(en),
            targetLayoutID: LayoutSwitcher.sourceID(ru))
    }

    private func snapshot(_ buffer: String) -> GenericShellEditorSnapshot {
        GenericShellEditorSnapshot(sessionPID: 42, tty: "/dev/ttys001",
            lineNonce: "D7607DCE-E311-498A-8305-D41E12E9CBA8.1", buffer: buffer,
            cursor: buffer.unicodeScalars.count, mark: 0, regionActive: 0)
    }

    private func request(_ context: CombinedShiftContext, reconvert: Bool) -> CombinedShiftRequest {
        CombinedShiftRequest(action: .convert(context), wordContext: context, wordKeys: [],
            prevWordKeys: [], lineKeys: [], lineSourceLayoutID: nil, boundaryCount: 0,
            reconvert: reconvert, inputRevision: 1, frontProcessID: 42, focus: nil)
    }

    @MainActor
    func testFirstPastedWordUndoRedoAndNewWordUseExactShellSnapshot() throws {
        let context = try layoutPair()
        let converter = TextConverter(selectionPreferences: { (true, false) })
        let coordinator = ManualShellCoordinator()
        let before = snapshot("ghbdtn")
        // No observed keys can set reconvert=true; this is still a fresh word.
        let first = try XCTUnwrap(coordinator.makeProposal(snapshot: before,
            request: request(context, reconvert: true), context: context,
            converter: converter, externalSelection: .collapsed, convertWholeLine: false))
        XCTAssertEqual(first.proposal.replacementBuffer, "привет")
        XCTAssertEqual(first.resultLayoutID, context.targetLayoutID)
        let after = snapshot(first.proposal.replacementBuffer)
        coordinator.recordConfirmed(before: before, after: after)
        let undo = try XCTUnwrap(coordinator.makeProposal(snapshot: after,
            request: request(context, reconvert: true), context: context,
            converter: converter, externalSelection: .collapsed, convertWholeLine: false))
        XCTAssertEqual(undo.proposal.replacementBuffer, "ghbdtn")
        coordinator.recordConfirmed(before: after, after: before)
        let redo = try XCTUnwrap(coordinator.makeProposal(snapshot: before,
            request: request(context, reconvert: true), context: context,
            converter: converter, externalSelection: .collapsed, convertWholeLine: false))
        XCTAssertEqual(redo.proposal.replacementBuffer, "привет")
        let newWord = snapshot("new ghbdtn")
        let next = try XCTUnwrap(coordinator.makeProposal(snapshot: newWord,
            request: request(context, reconvert: true), context: context,
            converter: converter, externalSelection: .collapsed, convertWholeLine: false))
        XCTAssertEqual(next.proposal.replacementBuffer, "new привет")
        XCTAssertNil(coordinator.makeProposal(snapshot: before,
            request: request(context, reconvert: true), context: context,
            converter: converter, externalSelection: .selected, convertWholeLine: false))
    }

    @MainActor
    func testReconvertDoesNotRestoreWholeBufferAfterZLESelectionChanges() throws {
        let context = try layoutPair()
        let converter = TextConverter(selectionPreferences: { (true, false) })
        let coordinator = ManualShellCoordinator()
        let before = snapshot("echo ghbdtn")
        let after = snapshot("echo привет")
        coordinator.recordConfirmed(before: before, after: after)
        let selected = GenericShellEditorSnapshot(sessionPID: after.sessionPID, tty: after.tty,
            lineNonce: after.lineNonce, buffer: after.buffer, cursor: after.cursor,
            mark: 8, regionActive: 1)
        let plan = try XCTUnwrap(coordinator.makeProposal(snapshot: selected,
            request: request(context.reversed, reconvert: true), context: context.reversed,
            converter: converter, externalSelection: .collapsed, convertWholeLine: false))
        XCTAssertEqual(plan.proposal.replacementBuffer, "echo приdtn")
        XCTAssertEqual(plan.proposal.replacementCursor, 11)
    }

    @MainActor
    func testDefaultDisabledAndDisableKeepsRecoveryState() {
        let coordinator = ManualShellCoordinator()
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(coordinator.hasInFlightEdit)
        XCTAssertFalse(coordinator.hasUnbackedUnknown)
        coordinator.configure(enabled: false)
        XCTAssertFalse(coordinator.isEnabled)
    }

    @MainActor
    func testQuitGateAndUnknownCapacityReleaseOnlyAfterVerifiedArchive() throws {
        let coordinator = ManualShellCoordinator()
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ms-shell-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        func source(_ line: Int) -> ManualShellCoordinator.RecoveryOriginal {
            .init(id: UUID(), text: "synthetic source \(line)", sessionPID: 42,
                tty: "/dev/ttys001", lineNonce: "D7607DCE-E311-498A-8305-D41E12E9CBA8.\(line)",
                archive: nil)
        }
        let first = source(1), firstID = UUID()
        XCTAssertTrue(coordinator.reserveInFlight(first, requestID: firstID))
        XCTAssertTrue(coordinator.hasInFlightEdit) // applicationShouldTerminate cancels here
        coordinator.configure(enabled: false)
        XCTAssertTrue(coordinator.hasInFlightEdit) // disabling cannot erase the original
        coordinator.finishInFlight(requestID: firstID, uncertain: true)
        XCTAssertFalse(coordinator.hasInFlightEdit)
        XCTAssertTrue(coordinator.hasUnbackedUnknown)
        for line in 2...8 {
            let id = UUID()
            XCTAssertTrue(coordinator.reserveInFlight(source(line), requestID: id))
            coordinator.finishInFlight(requestID: id, uncertain: true)
        }
        XCTAssertFalse(coordinator.reserveInFlight(source(9), requestID: UUID()))
        try coordinator.saveUncertainOriginals(in: directory)
        XCTAssertFalse(coordinator.hasUnbackedUnknown)
        XCTAssertEqual(coordinator.uncertainOriginals.count, 8)
        XCTAssertTrue(coordinator.uncertainOriginals.allSatisfy { $0.text == nil && $0.archive != nil })
        XCTAssertFalse(coordinator.reserveInFlight(first, requestID: UUID())) // same unknown line locked
        XCTAssertTrue(coordinator.reserveInFlight(source(9), requestID: UUID())) // new line unblocked
    }

    @MainActor
    func testPhysicalInputRevokesPendingShellAuthorizationImmediately() {
        let gate = ShellAuthorizationGate()
        let monitor = KeyboardMonitor()
        monitor.onInputRevisionAdvanced = { _ = gate.next() }
        let token = gate.next()
        XCTAssertTrue(gate.allows(token))
        monitor.handleKeyDown(keyCode: 0, flags: [], renderedText: "a")
        XCTAssertFalse(gate.allows(token))
    }

    @MainActor
    func testProvenMouseSelectionCollapsesCaretAtReplacementEnd() throws {
        let context = try layoutPair()
        let coordinator = ManualShellCoordinator()
        let converter = TextConverter(selectionPreferences: { (true, false) })
        let line = snapshot("echo ghbdtn suffix")
        XCTAssertNil(coordinator.makeProposal(snapshot: line,
            request: request(context, reconvert: true), context: context,
            converter: converter, externalSelection: .selected,
            convertWholeLine: false)) // no AX-tail proof
        let plan = try XCTUnwrap(coordinator.makeProposal(snapshot: line,
            request: request(context, reconvert: true), context: context,
            converter: converter, externalSelection: .selected,
            convertWholeLine: false, mouseSelection: 5..<11))
        XCTAssertEqual(plan.proposal.replacementBuffer, "echo привет suffix")
        XCTAssertEqual(plan.proposal.replacementCursor, 11)
        XCTAssertNil(coordinator.makeProposal(snapshot: line,
            request: request(context, reconvert: false), context: context,
            converter: converter, externalSelection: .selected,
            convertWholeLine: false, mouseSelection: 50..<60))
    }
}
