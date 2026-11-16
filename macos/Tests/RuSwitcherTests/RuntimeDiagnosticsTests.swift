import XCTest
@testable import RuSwitcher

final class RuntimeDiagnosticsTests: XCTestCase {
    func testDiagnosticsRequiresExactExplicitFlag() {
        XCTAssertFalse(RuntimeDiagnostics.isEnabled(arguments: ["MacSwitcher"]))
        XCTAssertFalse(RuntimeDiagnostics.isEnabled(arguments: ["MacSwitcher", "--diagnostic-events=false"]))
        XCTAssertFalse(RuntimeDiagnostics.isEnabled(arguments: ["MacSwitcher", "diagnostic-events"]))
        XCTAssertTrue(RuntimeDiagnostics.isEnabled(arguments: ["MacSwitcher", "--diagnostic-events"]))
    }

    func testCombinedOutcomeIdentifierIsClosedAndOptIn() {
        let pending = CombinedShiftDiagnostic(application: .chrome, operation: .recovery, result: .pending)
        XCTAssertNil(RuntimeDiagnostics.combinedIdentifier(pending, enabled: false))
        XCTAssertEqual(RuntimeDiagnostics.combinedIdentifier(pending, enabled: true),
            "combined.chrome.recovery.pending")
        let unknownUndo = CombinedShiftDiagnostic(application: .safari, operation: .undo, result: .uncertain)
        XCTAssertEqual(RuntimeDiagnostics.combinedIdentifier(unknownUndo, enabled: true),
            "combined.safari.undo.uncertain")
        let legacy = CombinedShiftDiagnostic(application: .browser, operation: .word, result: .confirmed)
        XCTAssertEqual(RuntimeDiagnostics.combinedIdentifier(legacy, enabled: true),
            "combined.browser.word.confirmed")
        XCTAssertNil(RuntimeDiagnostics.automaticUncertainIdentifier(.chrome, enabled: false))
        XCTAssertEqual(RuntimeDiagnostics.automaticUncertainIdentifier(.chrome, enabled: true),
            "automatic.chrome.uncertain")
    }

    func testVocabularyContainsOnlyUniqueStaticEventIdentifiers() {
        let names = RuntimeDiagnosticEvent.allCases.map(\.rawValue)
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isLetter) })
        XCTAssertFalse(RuntimeDiagnosticEvent.doubleReceived.logOnce)
        XCTAssertFalse(RuntimeDiagnosticEvent.soloReceived.logOnce)
        XCTAssertTrue(RuntimeDiagnosticEvent.autoUnicodeMissing.logOnce)
        XCTAssertTrue(RuntimeDiagnosticEvent.autoEditPosted.logOnce)
    }

    func testNativeAttemptRetainsItsFocusFailureEvenIfItOccurredEarlier() {
        let seen = RuntimeDiagnostics.SeenEvents()
        XCTAssertTrue(seen.insert(.focusReadCannotComplete))
        XCTAssertFalse(seen.insert(.focusReadCannotComplete))
        XCTAssertTrue(seen.insert(.autoEngineReady))
        seen.beginNativeFocusReadAttempt()
        XCTAssertTrue(seen.insert(.focusReadCannotComplete))
        XCTAssertFalse(seen.insert(.focusReadCannotComplete))
        XCTAssertFalse(seen.insert(.autoEngineReady))
    }

    func testLateAutomaticMilestonesRepeatOnlyAfterExistingInterval() {
        for event: RuntimeDiagnosticEvent in [.autoNoProposal, .autoTextConfirmed, .autoAnchorRetired] {
            var clock: UInt64 = 1
            let seen = RuntimeDiagnostics.SeenEvents(now: { clock })
            XCTAssertTrue(seen.shouldEmit(event))
            XCTAssertFalse(seen.shouldEmit(event))
            clock += 4_999_999_999
            XCTAssertFalse(seen.shouldEmit(event))
            clock += 1
            XCTAssertTrue(seen.shouldEmit(event))
            XCTAssertFalse(seen.shouldEmit(event))
        }
    }
}
