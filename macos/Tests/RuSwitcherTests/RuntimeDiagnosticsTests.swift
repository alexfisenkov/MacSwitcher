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
}
