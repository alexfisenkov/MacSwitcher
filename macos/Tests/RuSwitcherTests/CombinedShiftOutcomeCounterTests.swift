import ApplicationServices
import XCTest
@testable import RuSwitcher

/// Each terminal path of a recognized double Shift writes the counter named for it.
@MainActor
final class CombinedShiftOutcomeCounterTests: XCTestCase {
    private let context = CombinedShiftContext(sourceLayoutID: "fixture.en", targetLayoutID: "fixture.ru")

    private func request(selection: CFRange) -> CombinedShiftRequest {
        CombinedShiftRequest(action: .convert(context), wordContext: context, wordKeys: [],
            prevWordKeys: [], lineKeys: [], lineSourceLayoutID: nil, boundaryCount: 0,
            reconvert: false, inputRevision: 0, frontProcessID: 4401,
            focus: CombinedShiftFocus(processID: 4401, element: AXUIElementCreateApplication(4401),
                initialSelection: selection))
    }

    private func finish(succeeded: Bool, source: LayoutSelectionCommit.Outcome) -> [RuntimeDiagnosticEvent] {
        var events: [RuntimeDiagnosticEvent] = []
        let commit = NativeQueuedSourceCommit(isCurrent: { true }, request: { _ in source })
        _ = CombinedShiftCompletion.finish(succeeded: succeeded, request: request(selection: CFRange(location: 0, length: 0)),
            context: context, sourceCommit: commit, converter: TextConverter(), monitor: KeyboardMonitor(),
            isInputCurrent: { true }, record: { events.append($0) })
        return events
    }

    func testCompletionCountersMatchTheirNames() {
        XCTAssertEqual(finish(succeeded: false, source: .confirmed), [.doubleFailed])
        XCTAssertEqual(finish(succeeded: true, source: .confirmed), [.doubleSucceeded])
        XCTAssertEqual(finish(succeeded: true, source: .unconfirmed), [.doubleLayoutUnconfirmed])
    }

    private func run(selection: CFRange, sourceID: String,
                     lease: Bool) -> [RuntimeDiagnosticEvent] {
        var events: [RuntimeDiagnosticEvent] = []
        let monitor = KeyboardMonitor()
        let request = request(selection: selection)
        let execution = CombinedShiftExecutionContext(focus: request.focus!, inputRevision: monitor.inputRevision,
            currentInputRevision: { monitor.inputRevision })
        let fence = InputEventFence()
        let platform = CombinedShiftTransaction.Platform(currentSourceID: { sourceID },
            frontProcessID: { 4401 }, secureInputActive: { false },
            beginLease: { pid in lease ? fence.begin(processID: pid) : nil },
            leaseIsCurrent: { fence.isCurrent($0) }, leaseRemaining: { fence.remainingDuration($0) },
            finishLease: { lease, source in fence.finish(lease, replayLayoutID: source) },
            pendingSourceTargetID: { nil }, selectSource: { _ in .refused },
            noteUnconfirmedSource: { _, _ in }, observeWholeField: { _ in nil },
            applicationFamily: { .other })
        _ = CombinedShiftTransaction.run(request: request, context: context, execution: execution,
            converter: TextConverter(), monitor: monitor, platform: platform, convertWholeLine: false,
            contextForSource: { _ in nil }, diagnosticsEnabled: false, onEvent: { events.append($0) })
        return events
    }

    func testSelectionPreparationRefusalIsAFailureButFenceUnavailabilityIsNot() {
        let selected = run(selection: CFRange(location: 0, length: 3), sourceID: "fixture.en", lease: true)
        XCTAssertEqual(selected, [.doubleFailed])
        let noLease = run(selection: CFRange(location: 3, length: 0), sourceID: "fixture.ru", lease: false)
        XCTAssertEqual(noLease, [.nativeFenceUnavailable])
    }
}
