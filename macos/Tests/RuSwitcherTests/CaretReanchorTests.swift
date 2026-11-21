import ApplicationServices
import XCTest
@testable import RuSwitcher

/// The only path that may move an expected edit range: a collapsed caret that
/// moved forward with no new input, the typed original exactly before it.
@MainActor
final class CaretReanchorTests: XCTestCase {
    typealias Field = ProductionCombinedShiftEditingTests.Field
    typealias Sink = DoubleShiftRefusalCodeTests.Sink

    private func observation(_ text: String, caret: Int, selection: Int = 0) -> NativeFieldObservation {
        NativeFieldObservation(text: text, caretUTF16Location: caret, selectionLength: selection)
    }

    func testPolicyAcceptsOnlyForwardCollapsedStableCaretWithOriginalAndSameSuffix() {
        let read = observation("xghbdt tail", caret: 6)
        let live = CFRange(location: 6, length: 0)
        XCTAssertEqual(CaretReanchor.range(original: "ghbdt", snapshotCaret: 5, liveCaret: live,
            first: read, second: read, revisionUnchanged: true, snapshotSuffix: " tail").map { [$0.location, $0.length] },
            [1, 5])
        XCTAssertNil(CaretReanchor.range(original: "ghbdt", snapshotCaret: 5, liveCaret: live,
            first: read, second: read, revisionUnchanged: true, snapshotSuffix: " tall"), "suffix changed")
        XCTAssertNil(CaretReanchor.range(original: "ghbdt", snapshotCaret: 5, liveCaret: live,
            first: read, second: read, revisionUnchanged: false), "revision changed")
        XCTAssertNil(CaretReanchor.range(original: "ghbdt", snapshotCaret: 5, liveCaret: live,
            first: read, second: observation("xghbdt tail", caret: 5), revisionUnchanged: true), "reads differ")
        XCTAssertNil(CaretReanchor.range(original: "ghbdt", snapshotCaret: 7, liveCaret: live,
            first: read, second: read, revisionUnchanged: true), "caret moved back")
        let selected = observation("xghbdt tail", caret: 6, selection: 1)
        XCTAssertNil(CaretReanchor.range(original: "ghbdt", snapshotCaret: 5,
            liveCaret: CFRange(location: 6, length: 1), first: selected, second: selected,
            revisionUnchanged: true), "selection not collapsed")
        let other = observation("xghbdx tail", caret: 6)
        XCTAssertNil(CaretReanchor.range(original: "ghbdt", snapshotCaret: 5, liveCaret: live,
            first: other, second: other, revisionUnchanged: true), "original not before caret")
        let paragraph = observation("\nghbdt", caret: 6)
        XCTAssertNil(CaretReanchor.range(original: "ghbdt", snapshotCaret: 5, liveCaret: live,
            first: paragraph, second: paragraph, revisionUnchanged: true), "formatted coordinates")
    }

    /// First-tap focus whose suffix read ran after the callback (or never, if `ready` is false).
    static func firstTap(_ field: Field, monitor: KeyboardMonitor, ready: Bool = true) throws -> CombinedShiftFocus {
        var scheduled: [@MainActor () -> Void] = []
        monitor.suffixSnapshotScheduler = { scheduled.append($0) }
        let focus = try XCTUnwrap(monitor.attachingSuffixSnapshot(field.focus(),
            read: { _ in (field.selectedRange(), field.text) }))
        if ready { scheduled.forEach { $0() } }
        return focus
    }

    private func run(_ field: Field, sink: Sink, mutate: (Field) -> Void,
                     observe: ((CombinedShiftFocus) -> NativeFieldObservation?)? = nil,
                     advanceRevision: Bool = false, snapshotReady: Bool = true) throws -> Bool {
        let pair = try DoubleShiftRefusalCodeTests.pair()
        let monitor = KeyboardMonitor()
        let converter = DoubleShiftRefusalCodeTests.converter([field], sink: sink, observe: observe)
        try DoubleShiftRefusalCodeTests.type("ghbdt", source: pair.en, monitor: monitor)
        let first = try Self.firstTap(field, monitor: monitor, ready: snapshotReady)
        return try DoubleShiftRefusalCodeTests.gesture(field, monitor: monitor, converter: converter, pair: pair,
                                                       firstFocus: first) {
            mutate(field)
            if advanceRevision { monitor.resetCombinedShift() }
        }
    }

    func testForwardCaretWithOriginalBeforeItIsReanchoredAndEdited() throws {
        let pair = try DoubleShiftRefusalCodeTests.pair()
        let monitor = KeyboardMonitor()
        let field = Field(pid: 2201, text: "ghbdt")
        let sink = Sink()
        let converter = DoubleShiftRefusalCodeTests.converter([field], sink: sink)
        try DoubleShiftRefusalCodeTests.type("ghbdt", source: pair.en, monitor: monitor)
        let first = try Self.firstTap(field, monitor: monitor)
        XCTAssertTrue(try DoubleShiftRefusalCodeTests.gesture(field, monitor: monitor,
            converter: converter, pair: pair, firstFocus: first) {
            field.text = "xghbdt"
            field.caret = 6
        })
        XCTAssertEqual(field.text, "xприве")
        XCTAssertEqual(sink.events.filter { $0 == .doubleCaretReanchored }, [.doubleCaretReanchored])
        XCTAssertEqual(sink.failures, [])

        // The confirmed result is undoable at its re-anchored range.
        monitor.markConverted()
        XCTAssertTrue(try DoubleShiftRefusalCodeTests.gesture(field, monitor: monitor,
            converter: converter, pair: pair))
        XCTAssertEqual(field.text, "xghbdt")
    }

    func testBackwardSelectedUnstableOrStaleCaretRefusesWithoutWriting() throws {
        let cases: [(String, (Field) -> Void, Bool)] = [
            ("back", { $0.caret = 4 }, false),
            ("selection", { $0.text = "xghbdt"; $0.caret = 5; $0.selection = 1 }, false),
            ("revision", { $0.text = "xghbdt"; $0.caret = 6 }, true),
        ]
        for (index, item) in cases.enumerated() {
            let field = Field(pid: 2210 + Int32(index), text: "ghbdt")
            let sink = Sink()
            XCTAssertFalse(try run(field, sink: sink, mutate: item.1, advanceRevision: item.2), item.0)
            XCTAssertEqual(sink.failures, [.caretReanchorRefused], item.0)
            XCTAssertEqual(field.queuedText + field.queuedSelection, 0, item.0)
            XCTAssertFalse(sink.events.contains(.doubleCaretReanchored), item.0)
        }
    }

    func testDifferentConsecutiveReadsRefuseWithoutWriting() throws {
        let field = Field(pid: 2220, text: "ghbdt")
        let sink = Sink()
        var reads = 0
        XCTAssertFalse(try run(field, sink: sink, mutate: { field in
            field.text = "xghbdt"
            field.caret = 6
        }, observe: { _ in
            reads += 1
            return NativeFieldObservation(text: reads.isMultiple(of: 2) ? "xghbdt!" : "xghbdt",
                caretUTF16Location: 6, selectionLength: 0)
        }))
        XCTAssertEqual(sink.failures, [.caretReanchorRefused])
        XCTAssertEqual(field.queuedText + field.queuedSelection, 0)
    }

    func testSuffixChangedBetweenTapsRefusesWithReanchorCode() throws {
        let field = Field(pid: 2230, text: "ghbdt tail")
        field.caret = 5
        let sink = Sink()
        XCTAssertFalse(try run(field, sink: sink) { field in
            field.text = "xghbdt tall"
            field.caret = 6
        })
        XCTAssertEqual(sink.failures, [.caretReanchorRefused])
        XCTAssertEqual(field.queuedText + field.queuedSelection, 0)
    }

    func testUnchangedSuffixAfterCaretIsReanchored() throws {
        let field = Field(pid: 2231, text: "ghbdt tail")
        field.caret = 5
        let sink = Sink()
        XCTAssertTrue(try run(field, sink: sink) { field in
            field.text = "xghbdt tail"
            field.caret = 6
        })
        XCTAssertEqual(field.text, "xприве tail")
    }

    func testSnapshotNotReadyKeepsAlpha36Refusal() throws {
        let field = Field(pid: 2232, text: "ghbdt")
        let sink = Sink()
        XCTAssertFalse(try run(field, sink: sink, mutate: { field in
            field.text = "xghbdt"
            field.caret = 6
        }, snapshotReady: false))
        XCTAssertEqual(sink.failures, [.editSelectionDrifted])
        XCTAssertFalse(sink.events.contains(.doubleCaretReanchored))
        XCTAssertEqual(field.queuedText + field.queuedSelection, 0)
    }

    func testFirstTapCallbackDoesNotReadTheFieldValue() throws {
        let monitor = KeyboardMonitor()
        let field = Field(pid: 2233, text: "ghbdt tail")
        field.caret = 5
        var scheduled: [@MainActor () -> Void] = []
        var reads = 0
        monitor.suffixSnapshotScheduler = { scheduled.append($0) }
        let focus = try XCTUnwrap(monitor.attachingSuffixSnapshot(field.focus(), read: { _ in
            reads += 1
            return (field.selectedRange(), field.text)
        }))
        let snapshot = try XCTUnwrap(focus.suffixSnapshot)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(field.substringCount, 0)
        XCTAssertEqual(snapshot.state, .pending)
        XCTAssertEqual(scheduled.count, 1)
        scheduled.forEach { $0() }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(snapshot.state, .ready(" tail"))
    }
}
