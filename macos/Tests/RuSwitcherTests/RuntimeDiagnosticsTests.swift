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

    func testSecondaryClaudeAliasIsReadOnlyForEnabledUnknownApplication() {
        let privateAlias = "com.example.secondary-client"
        var aliasReads = 0
        let disabled = RuntimeDiagnostics.diagnosticApplicationFamily(
            bundleID: privateAlias, diagnosticsEnabled: false) {
                aliasReads += 1
                return privateAlias
            }
        XCTAssertEqual(disabled, .other)
        XCTAssertEqual(aliasReads, 0)

        let missingID = RuntimeDiagnostics.diagnosticApplicationFamily(
            bundleID: nil, diagnosticsEnabled: true) {
                aliasReads += 1
                return privateAlias
            }
        XCTAssertEqual(missingID, .other)
        XCTAssertEqual(aliasReads, 0)

        let known = RuntimeDiagnostics.diagnosticApplicationFamily(
            bundleID: "com.anthropic.claudefordesktop", diagnosticsEnabled: true) {
                aliasReads += 1
                return privateAlias
            }
        XCTAssertEqual(known, .claude)
        XCTAssertEqual(aliasReads, 0)

        let secondary = RuntimeDiagnostics.diagnosticApplicationFamily(
            bundleID: privateAlias, diagnosticsEnabled: true) {
                aliasReads += 1
                return privateAlias
            }
        XCTAssertEqual(secondary, .claudeSecondary)
        XCTAssertEqual(aliasReads, 1)
        let logged = RuntimeDiagnostics.combinedIdentifier(
            .init(application: secondary, operation: .word, result: .refused), enabled: true)
        XCTAssertEqual(logged, "combined.claudeSecondary.word.refused")
        XCTAssertFalse(logged?.contains(privateAlias) ?? true)
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
