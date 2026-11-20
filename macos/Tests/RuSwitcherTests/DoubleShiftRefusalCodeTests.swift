import ApplicationServices
import XCTest
@testable import RuSwitcher

/// Every refusal on the double-Shift edit path leaves exactly one closed code.
/// Fields, layouts and time are synthetic; no typed text reaches a sink.
@MainActor
final class DoubleShiftRefusalCodeTests: XCTestCase {
    typealias Field = ProductionCombinedShiftEditingTests.Field

    final class Sink {
        var failures: [RuntimeDiagnosticFailureReason] = []
        var events: [RuntimeDiagnosticEvent] = []
    }

    /// Wrapped so a trailing `beforeEdit` closure never binds to it.
    struct Barrier { let isActive: () -> Bool }

    struct Pair {
        let en: String
        let ru: String
        let enToRu: CombinedShiftContext
        var contexts: [String: CombinedShiftContext] { [en: enToRu, ru: enToRu.reversed] }
    }

    static func pair() throws -> Pair {
        let layouts = LayoutSwitcher.installedLayouts()
        let en = LayoutSwitcher.sourceID(try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" }))
        let ru = LayoutSwitcher.sourceID(try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" }))
        return Pair(en: en, ru: ru, enToRu: CombinedShiftContext(sourceLayoutID: en, targetLayoutID: ru))
    }

    static func converter(_ fields: [Field], sink: Sink,
                          observe: ((CombinedShiftFocus) -> NativeFieldObservation?)? = nil) -> TextConverter {
        TextConverter(selectionPreferences: { (false, true) },
            nativeEditBoundary: { selected, original, replacement, execution, barrier, prepared, queued, formattedStart, _, _, _ in
                guard let field = fields.first(where: {
                    $0.pid == execution.focus.processID && CFEqual($0.element, execution.focus.element)
                }) else { return .refused }
                let access = field.access(replacement: replacement, barrier: barrier)
                if selected {
                    return VerifiedNativeFieldEditor.executeSelection(original: original.text,
                        replacement: replacement, start: original.range.location, access: access,
                        onPrepared: prepared, onTextQueued: queued, formattedStart: formattedStart)
                }
                return VerifiedNativeFieldEditor.execute(original: original.text, replacement: replacement,
                    start: original.range.location, access: access,
                    onPrepared: prepared, onTextQueued: queued, formattedStart: formattedStart)
            }, wholeFieldObservationOverride: observe ?? { focus in
                fields.first(where: {
                    $0.pid == focus.processID && CFEqual($0.element, focus.element) && $0.valid
                })?.observation
            }, editFailureRecorder: { sink.failures.append($0) },
            editEventRecorder: { sink.events.append($0) })
    }

    static func type(_ text: String, source: String, monitor: KeyboardMonitor) throws {
        for character in text {
            let key = try XCTUnwrap(KeyMapping.keycodeToEN.first { $0.value == character }?.key)
            monitor.handleKeyDown(keyCode: key, flags: [], renderedSourceLayoutID: source)
        }
    }

    /// One production double-Shift edit: first and second tap snapshots, then
    /// CombinedShiftEditing.perform under an optional synthetic lease budget.
    static func gesture(_ field: Field, monitor: KeyboardMonitor, converter: TextConverter, pair: Pair,
                        budget: TimeInterval? = 0.250,
                        automaticUndo: DoubleShiftAutomaticUndo = .manual,
                        firstFocus: CombinedShiftFocus? = nil,
                        barrier: Barrier? = nil,
                        beforeEdit: () -> Void = {}) throws -> Bool {
        _ = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .switchLayout(pair.enToRu),
            frontProcessID: field.pid, focus: firstFocus ?? field.focus(), contextForSource: { pair.contexts[$0] }))
        let request = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .convert(pair.enToRu),
            frontProcessID: field.pid, focus: field.focus(), contextForSource: { pair.contexts[$0] }))
        let execution = CombinedShiftExecutionContext(focus: try XCTUnwrap(request.focus),
            inputRevision: request.inputRevision, currentInputRevision: { monitor.inputRevision })
        beforeEdit()
        converter.beginDiagnosticGesture()
        defer { converter.endDiagnosticGesture() }
        let edit = {
            CombinedShiftEditing.perform(request: request, context: pair.enToRu, execution: execution,
                converter: converter, inputBarrierIsActive: barrier?.isActive ?? { field.active }, convertWholeLine: false,
                contextForSource: { pair.contexts[$0] }, automaticUndo: automaticUndo)
        }
        guard let budget else { return edit() }
        return converter.withNativeInputBudget({ budget }, perform: edit)
    }

    func testExhaustedLeaseBudgetWritesItsCodeOncePerGesture() throws {
        let pair = try Self.pair()
        let monitor = KeyboardMonitor()
        let field = Field(pid: 2101, text: "ghbdtn")
        let sink = Sink()
        let converter = Self.converter([field], sink: sink)
        try Self.type("ghbdtn", source: pair.en, monitor: monitor)

        XCTAssertFalse(try Self.gesture(field, monitor: monitor, converter: converter, pair: pair, budget: 0.100))
        XCTAssertEqual(sink.failures, [.editBudgetExhausted])
        XCTAssertFalse(try Self.gesture(field, monitor: monitor, converter: converter, pair: pair, budget: 0.100))
        XCTAssertEqual(sink.failures, [.editBudgetExhausted, .editBudgetExhausted])
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(field.text, "ghbdtn")
    }

    func testStaleAutomaticRequestWritesItsCode() throws {
        let pair = try Self.pair()
        let monitor = KeyboardMonitor()
        let field = Field(pid: 2102, text: "ghbdtn")
        let sink = Sink()
        let converter = Self.converter([field], sink: sink)
        try Self.type("ghbdtn", source: pair.en, monitor: monitor)

        XCTAssertFalse(try Self.gesture(field, monitor: monitor, converter: converter, pair: pair,
            automaticUndo: .staleAutomatic))
        XCTAssertEqual(sink.failures, [.staleAutomaticRequest])
        XCTAssertEqual(field.queuedText, 0)
    }

    func testFieldLockIsWrittenOncePerGestureAndAgainNextGesture() throws {
        let pair = try Self.pair()
        let monitor = KeyboardMonitor()
        let field = Field(pid: 2103, text: "ghbdtn")
        let sink = Sink()
        let converter = Self.converter([field], sink: sink)
        try Self.type("ghbdtn", source: pair.en, monitor: monitor)
        field.dropInsertion = true
        XCTAssertFalse(try Self.gesture(field, monitor: monitor, converter: converter, pair: pair))
        let focus = field.focus()
        XCTAssertTrue(converter.hasUnconfirmedAXEdit(in: focus))
        sink.events = []

        converter.beginDiagnosticGesture()
        for _ in 0..<3 { XCTAssertTrue(converter.hasUnconfirmedAXEdit(in: focus)) }
        converter.endDiagnosticGesture()
        XCTAssertEqual(sink.events, [.recoverySameFieldBlocked])

        converter.beginDiagnosticGesture()
        XCTAssertTrue(converter.hasUnconfirmedAXEdit(in: focus))
        converter.endDiagnosticGesture()
        XCTAssertEqual(sink.events, [.recoverySameFieldBlocked, .recoverySameFieldBlocked])
    }

    // MARK: VerifiedNativeFieldEditor stages

    private func editorRun(_ field: Field, original: String = "ghbdtn",
                           deadline: TimeInterval? = nil,
                           adjust: (NativeFieldAccess) -> NativeFieldAccess = { $0 }) -> VerifiedNativeFieldEditResult {
        field.capturesEditorDiagnostics = true
        let access = adjust(field.access(replacement: "привет", barrier: { true }))
        return VerifiedNativeFieldEditor.execute(original: original, replacement: "привет",
            start: 0, access: access, absoluteDeadline: deadline)
    }

    func testEditorRefusalStagesEachWriteOneCode() {
        let readOnly = Field(pid: 2110, text: "ghbdtn")
        readOnly.readOnly = true
        XCTAssertEqual(editorRun(readOnly), .refused)
        XCTAssertEqual(readOnly.editorFailures, [.editorFieldNotEditable])

        let lost = Field(pid: 2111, text: "ghbdtn")
        lost.valid = false
        XCTAssertEqual(editorRun(lost), .refused)
        XCTAssertEqual(lost.editorFailures, [.editorIdentityLost])

        let mismatch = Field(pid: 2112, text: "ghbdtn")
        XCTAssertEqual(editorRun(mismatch, original: "ntdbhg"), .refused)
        XCTAssertEqual(mismatch.editorFailures, [.editorPlanRefused])

        let notQueued = Field(pid: 2113, text: "ghbdtn")
        notQueued.refuseBeforeQueue = true
        XCTAssertEqual(editorRun(notQueued), .refused)
        XCTAssertEqual(notQueued.editorFailures, [.editorPreparationNotQueued])

        let clock = Field(pid: 2114, text: "ghbdtn")
        XCTAssertEqual(editorRun(clock, deadline: clock.clock), .refused)
        XCTAssertEqual(clock.editorFailures, [.editorClockInvalid])

        for field in [readOnly, lost, mismatch, notQueued, clock] { XCTAssertEqual(field.queuedText, 0) }
    }

    func testAcknowledgementDeadlineSubcodes() {
        let source = Field(pid: 2120, text: "ghbdtn")
        source.dropInsertion = true
        guard case .uncertain = editorRun(source) else { return XCTFail("expected uncertain") }
        XCTAssertTrue(source.editorEvents.contains(.ackDeadline))
        XCTAssertTrue(source.editorEvents.contains(.ackDeadlineSourceVisible))
        XCTAssertFalse(source.editorEvents.contains(.ackDeadlineCaretOnly))
        XCTAssertFalse(source.editorEvents.contains(.ackDeadlineOther))

        let caret = Field(pid: 2121, text: "ghbdtn")
        caret.reportWrongCaretAfterText = true
        guard case .uncertain = editorRun(caret) else { return XCTFail("expected uncertain") }
        XCTAssertTrue(caret.editorEvents.contains(.ackDeadlineCaretOnly))
        XCTAssertFalse(caret.editorEvents.contains(.ackDeadlineSourceVisible))
        XCTAssertFalse(caret.editorEvents.contains(.ackDeadlineOther))

        let other = Field(pid: 2122, text: "ghbdtn")
        let result = editorRun(other) { base in
            NativeFieldAccess(validateOriginalIdentity: base.validateOriginalIdentity,
                cheapGate: base.cheapGate, isEditable: base.isEditable,
                observe: { deadline in
                    guard let observed = base.observe(deadline) else { return nil }
                    return other.queuedText > 0
                        ? NativeFieldObservation(text: "x", caretUTF16Location: 1, selectionLength: 0)
                        : observed
                }, postBatch: base.postBatch, cancelPreparedSelection: base.cancelPreparedSelection,
                now: base.now, pause: base.pause,
                recordFailure: base.recordFailure, recordEvent: base.recordEvent)
        }
        guard case .uncertain = result else { return XCTFail("expected uncertain") }
        XCTAssertTrue(other.editorEvents.contains(.ackDeadlineOther))
        XCTAssertFalse(other.editorEvents.contains(.ackDeadlineSourceVisible))
        XCTAssertFalse(other.editorEvents.contains(.ackDeadlineCaretOnly))
    }

    // MARK: Remaining reachable stages

    private func wrap(_ base: NativeFieldAccess,
                      observe: ((TimeInterval) -> NativeFieldObservation?)? = nil,
                      postBatch: (([NativeFieldEditOperation]) -> Bool)? = nil) -> NativeFieldAccess {
        NativeFieldAccess(validateOriginalIdentity: base.validateOriginalIdentity,
            cheapGate: base.cheapGate, isEditable: base.isEditable,
            observe: observe ?? base.observe, postBatch: postBatch ?? base.postBatch,
            cancelPreparedSelection: base.cancelPreparedSelection, now: base.now, pause: base.pause,
            recordFailure: base.recordFailure, recordEvent: base.recordEvent)
    }

    func testEditorReadPlanAndCancellationStagesEachWriteOneCode() {
        let unreadable = Field(pid: 2130, text: "ghbdtn")
        XCTAssertEqual(editorRun(unreadable) { self.wrap($0, observe: { _ in nil }) }, .refused)
        XCTAssertEqual(unreadable.editorFailures, [.editorFirstReadInvalid])

        let changed = Field(pid: 2131, text: "ghbdtn")
        var reads = 0
        XCTAssertEqual(editorRun(changed) { base in
            self.wrap(base, observe: { deadline in
                reads += 1
                guard let actual = base.observe(deadline) else { return nil }
                return reads == 1 ? actual : NativeFieldObservation(text: actual.text + "x",
                    caretUTF16Location: actual.caretUTF16Location, selectionLength: actual.selectionLength)
            })
        }, .refused)
        XCTAssertEqual(changed.editorFailures, [.editorFieldChanged])

        let rejected = Field(pid: 2132, text: "ghbdtn")
        XCTAssertEqual(editorRun(rejected) { base in
            self.wrap(base, postBatch: { operations in
                operations.contains(.insertReplacement) ? false : base.postBatch(operations)
            })
        }, .refused)
        XCTAssertEqual(rejected.editorFailures, [.editorReplacementNotQueued])
        XCTAssertEqual(rejected.text, "ghbdtn")

        // The prepared selection is never observed exactly; it is cancelled cleanly.
        let cancelled = Field(pid: 2133, text: "ghbdtn")
        XCTAssertEqual(editorRun(cancelled) { base in
            self.wrap(base, observe: { deadline in
                guard let actual = base.observe(deadline) else { return nil }
                return actual.selectionLength > 0 ? NativeFieldObservation(text: actual.text,
                    caretUTF16Location: actual.caretUTF16Location,
                    selectionLength: actual.selectionLength - 1) : actual
            })
        }, .refused)
        XCTAssertEqual(cancelled.editorFailures, [.editorPreparationCancelled])
        XCTAssertEqual(cancelled.text, "ghbdtn")
        for field in [unreadable, changed, rejected, cancelled] { XCTAssertEqual(field.queuedText, 0) }
    }

    func testBarrierLostAtEditEntryWritesItsCode() throws {
        let pair = try Self.pair()
        let monitor = KeyboardMonitor()
        let field = Field(pid: 2140, text: "ghbdtn")
        let sink = Sink()
        let converter = Self.converter([field], sink: sink)
        try Self.type("ghbdtn", source: pair.en, monitor: monitor)
        var checks = 0
        // Word entry and buffer edit admit the lease; it ends before the edit itself.
        XCTAssertFalse(try Self.gesture(field, monitor: monitor, converter: converter, pair: pair,
            barrier: Barrier { checks += 1; return checks < 3 }))
        XCTAssertEqual(sink.failures, [.editBarrierInactive])
        XCTAssertEqual(field.queuedText + field.queuedSelection, 0)
    }

    func testUncertainEditWithoutPreparedSourceWritesItsCode() throws {
        let pair = try Self.pair()
        let monitor = KeyboardMonitor()
        let field = Field(pid: 2141, text: "ghbdtn")
        let sink = Sink()
        // Synthetic editor seam: reports an unknown delivery without a prepared field read.
        let converter = TextConverter(selectionPreferences: { (false, true) },
            nativeEditBoundary: { _, _, _, _, _, _, _, _, _, _, _ in .uncertain(observation: nil) },
            wholeFieldObservationOverride: { _ in field.observation },
            editFailureRecorder: { sink.failures.append($0) },
            editEventRecorder: { sink.events.append($0) })
        try Self.type("ghbdtn", source: pair.en, monitor: monitor)
        XCTAssertFalse(try Self.gesture(field, monitor: monitor, converter: converter, pair: pair))
        XCTAssertEqual(sink.failures, [.editSourceUnretained])
        XCTAssertFalse(converter.hasUnconfirmedAXEdit(in: field.focus()))
    }
}
