import ApplicationServices
import XCTest
@testable import RuSwitcher

final class ProductionManualSourceCompletionTests: XCTestCase {
    typealias Field = ProductionCombinedShiftEditingTests.Field

    @MainActor
    private func layoutPair() throws -> (en: String, ru: String, direction: CombinedShiftContext) {
        let layouts = LayoutSwitcher.installedLayouts()
        let en = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let ru = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        let enID = LayoutSwitcher.sourceID(en), ruID = LayoutSwitcher.sourceID(ru)
        return (enID, ruID, CombinedShiftContext(sourceLayoutID: enID, targetLayoutID: ruID))
    }

    @MainActor
    private func request(_ action: CombinedShiftGesture.Action, monitor: KeyboardMonitor,
                         field: Field, direction: CombinedShiftContext) throws -> CombinedShiftRequest {
        try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: action, frontProcessID: field.pid,
            focus: field.focus(), contextForSource: { $0 == direction.sourceLayoutID ? direction : direction.reversed }))
    }

    @MainActor
    func testConfirmedManualTextWithRefusedSourceKeepsUndoAndNeedsNoUnicodeReplay() throws {
        let pair = try layoutPair()
        let monitor = KeyboardMonitor()
        let field = Field(pid: 3011, text: "ghbd")
        let converter = ProductionCombinedShiftEditingTests.converter(for: [field])
        for key in [UInt16(5), 4, 11, 2] {
            monitor.handleKeyDown(keyCode: key, flags: [], renderedSourceLayoutID: pair.en)
        }
        _ = try request(.switchLayout(pair.direction), monitor: monitor, field: field, direction: pair.direction)
        let first = try request(.convert(pair.direction), monitor: monitor, field: field, direction: pair.direction)
        let execution = CombinedShiftExecutionContext(focus: try XCTUnwrap(first.focus),
            inputRevision: first.inputRevision, currentInputRevision: { monitor.inputRevision })
        let sourceCommit = NativeQueuedSourceCommit(isCurrent: { true }, request: { _ in .refused })
        let changed = converter.withNativeInputBudget({ 0.250 }) {
            converter.withNativeTextQueuedHandler({ sourceCommit.textQueued(targetID: $0) }) {
                CombinedShiftEditing.perform(request: first, context: pair.direction,
                    execution: execution, converter: converter, inputBarrierIsActive: { true },
                    convertWholeLine: false, contextForSource: { _ in pair.direction })
            }
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(converter.hasReconversionState)
        let completion = CombinedShiftCompletion.finish(succeeded: changed, request: first,
            context: pair.direction, sourceCommit: sourceCommit, converter: converter,
            monitor: monitor, isInputCurrent: { true })
        XCTAssertEqual(completion, .sourceNotConfirmed(targetID: pair.ru, sourceOutcome: .refused))
        XCTAssertFalse(monitor.keysTypedSinceConversion,
            "The confirmed edit must become the immediate undo target despite source refusal")
        XCTAssertNotNil(CombinedShiftFailure.sourceNotConfirmed.userMessage)
        XCTAssertEqual(field.queuedText, 1)

        // A verified source selection changes no text. Undo is a separate,
        // explicit gesture against the original field and exact current word.
        monitor.recordObservedInputSource(pair.ru)
        XCTAssertEqual(field.queuedText, 1)
        _ = try request(.switchLayout(pair.direction.reversed), monitor: monitor,
            field: field, direction: pair.direction)
        let undo = try request(.convert(pair.direction.reversed), monitor: monitor,
            field: field, direction: pair.direction)
        XCTAssertTrue(undo.reconvert)
        let undoExecution = CombinedShiftExecutionContext(focus: try XCTUnwrap(undo.focus),
            inputRevision: undo.inputRevision, currentInputRevision: { monitor.inputRevision })
        let undoCommit = NativeQueuedSourceCommit(isCurrent: { true }, request: { _ in .confirmed })
        let restored = converter.withNativeInputBudget({ 0.250 }) {
            converter.withNativeTextQueuedHandler({ undoCommit.textQueued(targetID: $0) }) {
                CombinedShiftEditing.perform(request: undo, context: pair.direction.reversed,
                    execution: undoExecution, converter: converter, inputBarrierIsActive: { true },
                    convertWholeLine: false, contextForSource: { _ in pair.direction.reversed })
            }
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.queuedText, 2)
    }

    @MainActor
    func testConfirmedManualTextWithUnconfirmedSourceWaitsForActualObservation() throws {
        let pair = try layoutPair()
        let monitor = KeyboardMonitor()
        let field = Field(pid: 3012, text: "ghbd")
        let converter = ProductionCombinedShiftEditingTests.converter(for: [field])
        for key in [UInt16(5), 4, 11, 2] {
            monitor.handleKeyDown(keyCode: key, flags: [], renderedSourceLayoutID: pair.en)
        }
        _ = try request(.switchLayout(pair.direction), monitor: monitor, field: field, direction: pair.direction)
        let request = try request(.convert(pair.direction), monitor: monitor, field: field, direction: pair.direction)
        let execution = CombinedShiftExecutionContext(focus: try XCTUnwrap(request.focus),
            inputRevision: request.inputRevision, currentInputRevision: { monitor.inputRevision })
        let sourceCommit = NativeQueuedSourceCommit(isCurrent: { true }, request: { _ in .unconfirmed },
            onUnconfirmed: { target in monitor.noteUnconfirmedInputSource(target,
                requestedAt: DispatchTime.now().uptimeNanoseconds) })
        let changed = converter.withNativeInputBudget({ 0.250 }) {
            converter.withNativeTextQueuedHandler({ sourceCommit.textQueued(targetID: $0) }) {
                CombinedShiftEditing.perform(request: request, context: pair.direction,
                    execution: execution, converter: converter, inputBarrierIsActive: { true },
                    convertWholeLine: false, contextForSource: { _ in pair.direction })
            }
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(field.text, "прив")
        XCTAssertTrue(monitor.hasPendingInputSourceTransition)
        XCTAssertEqual(CombinedShiftCompletion.finish(succeeded: changed, request: request,
            context: pair.direction, sourceCommit: sourceCommit, converter: converter,
            monitor: monitor, isInputCurrent: { true }),
            .sourceNotConfirmed(targetID: pair.ru, sourceOutcome: .unconfirmed))
        XCTAssertFalse(monitor.keysTypedSinceConversion)
        XCTAssertEqual(field.queuedText, 1)
        monitor.recordObservedInputSource(pair.en)
        XCTAssertTrue(monitor.hasPendingInputSourceTransition)
        monitor.recordObservedInputSource(pair.ru)
        XCTAssertFalse(monitor.hasPendingInputSourceTransition)
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(converter.hasReconversionState)
    }
}
