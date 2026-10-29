import ApplicationServices
import XCTest
@testable import RuSwitcher

final class RuntimeDiagnosticFailureTests: XCTestCase {
    func testFailureIdentifiersAreClosedAndDisabledProducesNoOutput() {
        let reasons = RuntimeDiagnosticFailureReason.allCases
        XCTAssertFalse(reasons.isEmpty)
        XCTAssertTrue(reasons.allSatisfy {
            RuntimeDiagnostics.failureIdentifier($0, enabled: false) == nil
        })
        let identifiers = reasons.compactMap {
            RuntimeDiagnostics.failureIdentifier($0, enabled: true)
        }
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertTrue(identifiers.allSatisfy {
            $0.hasPrefix("failure.") && $0.dropFirst("failure.".count).allSatisfy(\.isLetter)
        })
        var emitted: [String] = []
        RuntimeDiagnostics.emitFailure(.selectionSourceMismatch, enabled: false) { emitted.append($0) }
        XCTAssertTrue(emitted.isEmpty)
        RuntimeDiagnostics.emitFailure(.selectionSourceMismatch, enabled: true) { emitted.append($0) }
        RuntimeDiagnostics.emitFailure(.selectionSourceMismatch, enabled: true) { emitted.append($0) }
        XCTAssertEqual(emitted, ["failure.selectionSourceMismatch", "failure.selectionSourceMismatch"],
                       "A repeated refusal must not be deduplicated")
    }

    @MainActor
    func testSelectionBaselineReportsTheGuardThatRefused() throws {
        let field = ProductionCombinedShiftEditingTests.Field(pid: 5291, text: "ghbdtn")
        field.caret = 0
        var reasons: [RuntimeDiagnosticFailureReason] = []
        let converter = TextConverter(wholeFieldObservationOverride: { _ in field.observation })
        func baseline() -> TextConverter.NativeSelectionBaseline? {
            let execution = CombinedShiftExecutionContext(focus: field.focus(), inputRevision: 1,
                currentInputRevision: { 1 })
            return converter.nativeSelectionBaseline(execution: execution, onFailure: { reasons.append($0) })
        }

        XCTAssertNil(baseline())
        XCTAssertEqual(reasons, [.selectionStateBlocked])

        field.selection = field.text.utf16.count
        field.valid = false
        XCTAssertNil(baseline())
        XCTAssertEqual(reasons.last, .selectionInvalidExecution)

        field.valid = true
        XCTAssertNotNil(baseline())
        XCTAssertEqual(reasons.count, 2)
    }

    @MainActor
    func testPreparationSourceMismatchReportsPolicyStageWithoutReadingField() {
        let field = ProductionCombinedShiftEditingTests.Field(pid: 5292, text: "ghbdtn")
        field.caret = 0
        field.selection = field.text.utf16.count
        var reads = 0
        let converter = TextConverter(wholeFieldObservationOverride: { _ in
            reads += 1
            return field.observation
        })
        let execution = CombinedShiftExecutionContext(focus: field.focus(), inputRevision: 1,
            currentInputRevision: { 1 })
        var reasons: [RuntimeDiagnosticFailureReason] = []
        let result = converter.prepareNativeSelection(
            context: CombinedShiftContext(sourceLayoutID: "source", targetLayoutID: "target"),
            execution: execution, restorePrevious: false, observedSourceLayoutID: "source",
            onFailure: { reasons.append($0) })
        XCTAssertNil(result)
        XCTAssertEqual(reasons, [.selectionSourceMismatch])
        XCTAssertEqual(reads, 0)
    }
}
