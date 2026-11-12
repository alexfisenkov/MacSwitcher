import XCTest
@testable import RuSwitcher

final class RuntimeDiagnosticsTests: XCTestCase {
    func testDiagnosticsRequiresExactExplicitFlag() {
        XCTAssertFalse(RuntimeDiagnostics.isEnabled(arguments: ["MacSwitcher"]))
        XCTAssertFalse(RuntimeDiagnostics.isEnabled(arguments: ["MacSwitcher", "--diagnostic-events=false"]))
        XCTAssertFalse(RuntimeDiagnostics.isEnabled(arguments: ["MacSwitcher", "diagnostic-events"]))
        XCTAssertTrue(RuntimeDiagnostics.isEnabled(arguments: ["MacSwitcher", "--diagnostic-events"]))
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
