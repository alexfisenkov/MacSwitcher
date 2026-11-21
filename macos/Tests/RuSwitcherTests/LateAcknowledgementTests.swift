import ApplicationServices
import XCTest
@testable import RuSwitcher

/// A late editor applies the queued text after the ACK deadline. The check
/// only reads the field; the synthetic field counts every queued operation.
@MainActor
final class LateAcknowledgementTests: XCTestCase {
    typealias Field = ProductionCombinedShiftEditingTests.Field
    typealias Sink = DoubleShiftRefusalCodeTests.Sink

    @MainActor
    final class ManualClock {
        var pending: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        var scheduler: LateAcknowledgementCheck.Scheduler {
            { [unowned self] delay, work in pending.append((delay, work)) }
        }
        /// Runs the checks due up to `time` (seconds after lease release).
        func advance(to time: TimeInterval) {
            let due = pending.filter { $0.delay <= time }
            pending.removeAll { $0.delay <= time }
            for item in due.sorted(by: { $0.delay < $1.delay }) { item.work() }
        }
    }

    struct Setup {
        let pair: DoubleShiftRefusalCodeTests.Pair
        let monitor: KeyboardMonitor
        let field: Field
        let sink: Sink
        let converter: TextConverter
        let execution: CombinedShiftExecutionContext
    }

    /// The first gesture queues text that the field applies only later.
    private func lateGesture(pid: Int32) throws -> Setup {
        let pair = try DoubleShiftRefusalCodeTests.pair()
        let monitor = KeyboardMonitor()
        let field = Field(pid: pid, text: "ghbdtn")
        let sink = Sink()
        let converter = DoubleShiftRefusalCodeTests.converter([field], sink: sink)
        try DoubleShiftRefusalCodeTests.type("ghbdtn", source: pair.en, monitor: monitor)
        _ = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .switchLayout(pair.enToRu),
            frontProcessID: field.pid, focus: field.focus(), contextForSource: { pair.contexts[$0] }))
        let request = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .convert(pair.enToRu),
            frontProcessID: field.pid, focus: field.focus(), contextForSource: { pair.contexts[$0] }))
        let execution = CombinedShiftExecutionContext(focus: try XCTUnwrap(request.focus),
            inputRevision: request.inputRevision, currentInputRevision: { monitor.inputRevision })
        field.defersInsertion = true
        converter.beginDiagnosticGesture()
        let edited = converter.withNativeInputBudget({ 0.250 }) {
            CombinedShiftEditing.perform(request: request, context: pair.enToRu, execution: execution,
                converter: converter, inputBarrierIsActive: { field.active }, convertWholeLine: false,
                contextForSource: { pair.contexts[$0] })
        }
        converter.endDiagnosticGesture()
        XCTAssertFalse(edited)
        XCTAssertTrue(converter.hasUnconfirmedAXEdit(in: field.focus()))
        return Setup(pair: pair, monitor: monitor, field: field, sink: sink,
            converter: converter, execution: execution)
    }

    func testLateApplicationIsConfirmedUnlocksFieldAndArmsUndo() throws {
        let setup = try lateGesture(pid: 2301)
        let clock = ManualClock()
        var confirmed = 0
        XCTAssertTrue(setup.converter.scheduleLateAcknowledgement(execution: setup.execution,
            read: { setup.field.observation }, schedule: clock.scheduler) {
            confirmed += 1
            setup.monitor.markConverted()
        })
        let queued = (setup.field.queuedText, setup.field.queuedSelection)
        clock.advance(to: 0.250)
        setup.field.applyDeferredInsertion()   // the editor lands the text at 250 ms
        XCTAssertEqual(setup.field.text, "привет")
        clock.advance(to: 0.800)
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(setup.sink.events.filter { $0 == .ackLateConfirmed }, [.ackLateConfirmed])
        XCTAssertEqual(setup.field.queuedText, queued.0)
        XCTAssertEqual(setup.field.queuedSelection, queued.1)

        // Story 9a: neither automatic editing nor the next gesture is blocked.
        setup.sink.events = []
        setup.converter.beginDiagnosticGesture()
        XCTAssertFalse(setup.converter.hasUnconfirmedAXEdit(in: setup.field.focus()))
        setup.converter.endDiagnosticGesture()
        XCTAssertFalse(setup.sink.events.contains(.recoverySameFieldBlocked))
        setup.field.defersInsertion = false
        XCTAssertTrue(try DoubleShiftRefusalCodeTests.gesture(setup.field, monitor: setup.monitor,
            converter: setup.converter, pair: setup.pair))
        XCTAssertEqual(setup.field.text, "ghbdtn", "the confirmed result is undone as a normal repeat")
    }

    func testMismatchOrChangedRevisionKeepsLockAndNeverWrites() throws {
        for scenario in ["value", "revision", "element"] {
            let setup = try lateGesture(pid: scenario == "value" ? 2310 : scenario == "revision" ? 2311 : 2312)
            let clock = ManualClock()
            var confirmed = 0
            XCTAssertTrue(setup.converter.scheduleLateAcknowledgement(execution: setup.execution,
                read: { setup.field.observation }, schedule: clock.scheduler) { confirmed += 1 })
            let queued = (setup.field.queuedText, setup.field.queuedSelection, setup.field.text)
            switch scenario {
            case "value":
                break   // the editor never applies the text
            case "revision":
                setup.field.applyDeferredInsertion()
                setup.monitor.resetCombinedShift()
            default:
                setup.field.applyDeferredInsertion()
                setup.field.valid = false
            }
            let afterChange = setup.field.text
            clock.advance(to: 1.0)
            XCTAssertEqual(confirmed, 0, scenario)
            XCTAssertFalse(setup.sink.events.contains(.ackLateConfirmed), scenario)
            setup.field.valid = true
            XCTAssertTrue(setup.converter.hasUnconfirmedAXEdit(in: setup.field.focus()), scenario)
            XCTAssertEqual(setup.field.queuedText, queued.0, scenario)
            XCTAssertEqual(setup.field.queuedSelection, queued.1, scenario)
            XCTAssertEqual(setup.field.text, afterChange, scenario)
        }
    }
}
