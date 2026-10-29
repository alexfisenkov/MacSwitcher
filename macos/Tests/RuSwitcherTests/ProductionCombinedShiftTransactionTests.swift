import ApplicationServices
import XCTest
@testable import RuSwitcher

/// Exercises the same lease/edit/source transaction that AppDelegate calls.
/// Only AX, HID delivery and TIS are replaced with synthetic boundaries.
final class ProductionCombinedShiftTransactionTests: XCTestCase {
    typealias Field = ProductionCombinedShiftEditingTests.Field

    @MainActor
    private final class Rig {
        let monitor = KeyboardMonitor()
        let fence = InputEventFence()
        let fields: [Field]
        let enToRu: CombinedShiftContext
        let ruToEn: CombinedShiftContext
        var frontField: Field
        var sourceID: String
        var policyDelay: TimeInterval = 0
        var policySawLease = false
        var sourceRequests = 0
        var sourceOutcome: LayoutSelectionCommit.Outcome = .confirmed
        var wholeObservationAvailable = true
        var reportWrongCaretAfterText = false
        var selectionKnownWord: ((String, String) -> Bool?)?

        lazy var converter = TextConverter(selectionPreferences: { [unowned self] in
            policySawLease = fence.hasActiveLease
            if policyDelay > 0 { Thread.sleep(forTimeInterval: policyDelay) }
            return (false, true)
        }, nativeEditBoundary: { [unowned self] selected, original, replacement, execution,
                barrier, prepared, queued in
            guard let field = fields.first(where: {
                $0.pid == execution.focus.processID && CFEqual($0.element, execution.focus.element)
            }) else { return .refused }
            let base = field.access(replacement: replacement, barrier: barrier)
            var textWasQueued = false
            let access = NativeFieldAccess(
                validateOriginalIdentity: base.validateOriginalIdentity,
                cheapGate: base.cheapGate,
                isEditable: base.isEditable,
                observe: { [unowned self] deadline in
                    guard let observed = base.observe(deadline) else { return nil }
                    guard reportWrongCaretAfterText, textWasQueued else { return observed }
                    return NativeFieldObservation(text: observed.text,
                        caretUTF16Location: max(0, observed.caretUTF16Location - 1),
                        selectionLength: observed.selectionLength)
                }, postBatch: { operations in
                    let accepted = base.postBatch(operations)
                    if accepted && operations.contains(.insertReplacement) { textWasQueued = true }
                    return accepted
                }, cancelPreparedSelection: base.cancelPreparedSelection,
                now: base.now, pause: base.pause)
            if selected {
                return VerifiedNativeFieldEditor.executeSelection(original: original.text,
                    replacement: replacement, start: original.range.location, access: access,
                    onPrepared: prepared, onTextQueued: queued)
            }
            return VerifiedNativeFieldEditor.execute(original: original.text,
                replacement: replacement, start: original.range.location, access: access,
                onPrepared: prepared, onTextQueued: queued)
        }, wholeFieldObservationOverride: { [unowned self] focus in
            guard wholeObservationAvailable else { return nil }
            return fields.first(where: { $0.pid == focus.processID
                && CFEqual($0.element, focus.element) && $0.valid })?.observation
        })

        init(fields: [Field]) throws {
            let layouts = LayoutSwitcher.installedLayouts()
            let english = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
            let russian = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
            let en = LayoutSwitcher.sourceID(english), ru = LayoutSwitcher.sourceID(russian)
            enToRu = CombinedShiftContext(sourceLayoutID: en, targetLayoutID: ru)
            ruToEn = enToRu.reversed
            self.fields = fields
            frontField = fields[0]
            sourceID = en
        }

        func type(_ text: String, source: String) throws {
            let map = source == enToRu.sourceLayoutID ? KeyMapping.keycodeToEN : KeyMapping.keycodeToRU
            for character in text {
                let code = try XCTUnwrap(map.first(where: { $0.value == character })?.key)
                monitor.handleKeyDown(keyCode: code, flags: [], renderedSourceLayoutID: source)
            }
        }

        func request(_ direction: CombinedShiftContext) throws -> CombinedShiftRequest {
            let contexts = [enToRu.sourceLayoutID: enToRu, ruToEn.sourceLayoutID: ruToEn]
            _ = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .switchLayout(direction),
                frontProcessID: frontField.pid, focus: frontField.focus(),
                contextForSource: { contexts[$0] }))
            return try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .convert(direction),
                frontProcessID: frontField.pid, focus: frontField.focus(),
                contextForSource: { contexts[$0] }))
        }

        func run(_ request: CombinedShiftRequest,
                 direction: CombinedShiftContext) -> CombinedShiftTransaction.Result {
            let execution = CombinedShiftExecutionContext(focus: request.focus!,
                inputRevision: request.inputRevision,
                currentInputRevision: { [unowned self] in monitor.inputRevision })
            let platform = CombinedShiftTransaction.Platform(
                currentSourceID: { [unowned self] in sourceID },
                frontProcessID: { [unowned self] in frontField.pid },
                secureInputActive: { [unowned self] in frontField.secure },
                beginLease: { [unowned self] pid in fence.begin(processID: pid, maximumDuration: 0.250) },
                leaseIsCurrent: { [unowned self] lease in fence.isCurrent(lease) },
                leaseRemaining: { [unowned self] lease in fence.remainingDuration(lease) },
                finishLease: { [unowned self] lease, source in fence.finish(lease, replayLayoutID: source) },
                pendingSourceTargetID: { nil },
                selectSource: { [unowned self] target in
                    sourceRequests += 1
                    if sourceOutcome == .confirmed { sourceID = target }
                    return sourceOutcome
                }, noteUnconfirmedSource: { [unowned self] target, at in
                    monitor.noteUnconfirmedInputSource(target, requestedAt: at)
                },
                observeWholeField: { [unowned self] focus in
                    guard wholeObservationAvailable else { return nil }
                    return fields.first(where: { $0.pid == focus.processID
                        && CFEqual($0.element, focus.element) && $0.valid })?.observation
                }, applicationFamily: { .textEdit })
            return CombinedShiftTransaction.run(request: request, context: direction,
                execution: execution, converter: converter, monitor: monitor,
                platform: platform, convertWholeLine: false,
                contextForSource: { [unowned self] source in
                    source == enToRu.sourceLayoutID ? enToRu
                        : source == ruToEn.sourceLayoutID ? ruToEn : nil
                }, selectionKnownWord: selectionKnownWord)
        }
    }

    /// The actual prediction coordinator, with only editor/AX/TIS boundaries
    /// supplied by a synthetic field. No scoring or coordinator branch is copied.
    @MainActor
    private final class AutoRig {
        let monitor = KeyboardMonitor()
        let probe = PredictionEvaluationProbe()
        let field = Field(pid: 5110, text: "")
        let en: String
        let ru: String
        var sourceID: String
        var activeLease: InputEventFence.Lease?
        var generation: UInt64 = 0
        var sourceRequests = 0
        var undoSourceOutcome: LayoutSelectionCommit.Outcome = .confirmed
        var receiptClock = DispatchTime.now().uptimeNanoseconds
        var applied: [String] = []
        var correctionNotices: [ConfirmedCorrectionNotice] = []
        var confirmedAutoUndos: [ConfirmedCorrectionNotice] = []

        lazy var converter = ProductionCombinedShiftEditingTests.converter(for: [field],
            automaticRoute: { _, _, _ in .nativeVerified })

        lazy var platform = PredictionCoordinatorPlatform(
            frontmost: { [unowned self] in ("com.apple.TextEdit", field.pid) },
            currentLayoutID: { [unowned self] in sourceID },
            route: { _, _, _ in .nativeVerified }, deniedApp: { _ in false },
            autoSwitchEnabled: { true }, autoConvertEnabled: { true },
            remoteDeferred: { false }, secureInputActive: { false },
            captureFocus: { [unowned self] pid in pid == field.pid ? field.focus() : nil },
            focusIsCurrent: { [unowned self] focus in
                focus.processID == field.pid && CFEqual(focus.element, field.element)
            }, beginLease: { [unowned self] pid in
                guard activeLease == nil else { return nil }
                generation &+= 1
                let lease = InputEventFence.Lease(generation: generation, processID: pid)
                activeLease = lease
                return lease
            }, leaseIsCurrent: { [unowned self] lease in activeLease == lease },
            leaseRemaining: { [unowned self] lease in activeLease == lease ? 0.250 : nil },
            finishLease: { [unowned self] lease, _ in
                if activeLease == lease { activeLease = nil }
            }, selectSource: { [unowned self] target in
                sourceRequests += 1
                sourceID = target
                return .confirmed
            }, sourceRequestedAt: { DispatchTime.now().uptimeNanoseconds },
            noteUnconfirmedSource: { [unowned self] target, at in
                monitor.noteUnconfirmedInputSource(target, requestedAt: at)
            })

        lazy var coordinator: PredictionCoordinator = {
            let lexicon = PredictionLexicon(wordsByLanguage: [
                "ru": ["привет": 1_000_000, "думаю": 800_000, "что-то": 600_000,
                       "такое": 500_000, "а": 8_000_000],
                "en": ["hello": 900_000, "press": 500_000, "f": 20_000]
            ])
            let value = PredictionCoordinator(monitor: monitor, converter: converter,
                platform: platform, engine: PredictionEngine(lexicon: lexicon),
                receiptNow: { [unowned self] in receiptClock })
            value.onApplied = { [unowned self] word in applied.append(word) }
            value.onCorrection = { [unowned self] in correctionNotices.append($0) }
            value.onConfirmedAutomaticUndo = { [unowned self] in confirmedAutoUndos.append($0) }
            value.onEvaluationFinished = { [weak probe] evaluationID, outcome in probe?.finished(evaluationID, outcome) }
            value.onRenderRetryScheduled = { [weak probe] evaluationID in probe?.retryScheduled(evaluationID) }
            monitor.onPredictionInput = { [weak value, weak probe] snapshot in
                value?.submit(snapshot)
                probe?.submitted(value?.latestSubmittedEvaluationID)
            }
            monitor.onPredictionInvalidated = { [weak value] in value?.invalidate() }
            return value
        }()

        init() throws {
            let layouts = LayoutSwitcher.installedLayouts()
            let english = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
            let russian = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
            en = LayoutSwitcher.sourceID(english)
            ru = LayoutSwitcher.sourceID(russian)
            sourceID = en
        }

        func deliver(_ text: String, source: String? = nil) {
            field.type(text)
            monitor.recordPredictionText(text, processID: field.pid, sourceLayoutID: source ?? sourceID)
        }

        func deliverPhysicalEnglishKeys(_ raw: String) {
            for character in raw {
                if character == " " { deliver(" "); continue }
                guard let code = KeyMapping.keycodeToEN.first(where: { $0.value == character })?.key else {
                    preconditionFailure("Synthetic fixture lacks a physical key mapping")
                }
                let rendered = sourceID == en ? character : (KeyMapping.keycodeToRU[code] ?? character)
                deliver(String(rendered), source: sourceID)
            }
        }

        func settle(expected: PredictionEvaluationOutcome? = nil) {
            probe.awaitLatest(expected: expected)
        }

        func undoByDoubleShift(direction requestedDirection: CombinedShiftContext? = nil,
                               sourceAfterFirst: String? = nil,
                               notificationAfterFirst: String? = nil) throws -> CombinedShiftTransaction.Result {
            let direction = requestedDirection ?? CombinedShiftContext(sourceLayoutID: ru, targetLayoutID: en)
            let contexts = [en: direction.reversed, ru: direction]
            _ = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .switchLayout(direction),
                frontProcessID: field.pid, focus: field.focus(), contextForSource: { contexts[$0] }))
            sourceID = sourceAfterFirst ?? direction.targetLayoutID
            if let notificationAfterFirst {
                monitor.recordObservedInputSource(notificationAfterFirst)
                monitor.resetLineBuffer(sourceLayoutID: notificationAfterFirst)
            }
            let request = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .convert(direction),
                frontProcessID: field.pid, focus: field.focus(), contextForSource: { contexts[$0] }))
            XCTAssertTrue(request.reconvert)
            let execution = CombinedShiftExecutionContext(focus: try XCTUnwrap(request.focus),
                inputRevision: request.inputRevision,
                currentInputRevision: { [unowned self] in monitor.inputRevision })
            let fence = InputEventFence()
            let manualPlatform = CombinedShiftTransaction.Platform(
                currentSourceID: { [unowned self] in sourceID },
                frontProcessID: { [unowned self] in field.pid },
                secureInputActive: { false },
                beginLease: { pid in fence.begin(processID: pid, maximumDuration: 0.250) },
                leaseIsCurrent: { fence.isCurrent($0) },
                leaseRemaining: { fence.remainingDuration($0) },
                finishLease: { lease, target in fence.finish(lease, replayLayoutID: target) },
                pendingSourceTargetID: { nil },
                selectSource: { [unowned self] target in
                    if undoSourceOutcome == .confirmed { sourceID = target }
                    return undoSourceOutcome
                }, noteUnconfirmedSource: { _, _ in },
                observeWholeField: { [unowned self] focus in
                    CFEqual(focus.element, field.element) ? field.observation : nil
                }, applicationFamily: { .textEdit })
            let automaticUndo = coordinator.claimDoubleShiftAutomaticUndo(
                request: request, context: direction, observedSourceID: sourceID)
            let result = CombinedShiftTransaction.run(request: request, context: direction,
                execution: execution, converter: converter, monitor: monitor,
                platform: manualPlatform, convertWholeLine: false,
                contextForSource: { contexts[$0] }, automaticUndo: automaticUndo)
            if let receipt = result.confirmedAutomaticUndo {
                coordinator.completeDoubleShiftAutomaticUndo(receipt)
            }
            return result
        }
    }

    /// The old lease-first production transaction fails this selected edit:
    /// 275 ms of pure policy consumes the 250 ms input lease before Unicode.
    @MainActor
    func testSlowMixedSelectionUsesProductionPreparationBeforeLease() throws {
        let field = Field(pid: 5101, text: "ghbdtn MacSwitcher")
        field.caret = 0
        field.selection = field.text.utf16.count
        let rig = try Rig(fields: [field])
        rig.policyDelay = 0.275
        rig.sourceID = rig.enToRu.targetLayoutID // first solo Shift already changed TIS
        let result = rig.run(try rig.request(rig.enToRu), direction: rig.enToRu)
        XCTAssertFalse(rig.policySawLease)
        XCTAssertEqual(result.outcome, .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "привет MacSwitcher")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(rig.sourceRequests, 1)
    }

    @MainActor
    func testRepeatedWordUndoNextWordPauseAndFieldChange() throws {
        let first = Field(pid: 5102, text: "ghbdtn")
        let second = Field(pid: 5102, text: "ghbdtn", element: AXUIElementCreateSystemWide())
        let rig = try Rig(fields: [first, second])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(first.text, "привет")

        rig.sourceID = rig.ruToEn.targetLayoutID
        let undo = try rig.request(rig.ruToEn)
        XCTAssertTrue(undo.reconvert)
        XCTAssertEqual(rig.run(undo, direction: rig.ruToEn).outcome,
            .confirmed(resultID: rig.ruToEn.targetLayoutID))
        XCTAssertEqual(first.text, "ghbdtn")

        first.type(" ")
        rig.monitor.handleKeyDown(keyCode: KC.space, flags: [],
            renderedSourceLayoutID: rig.enToRu.sourceLayoutID)
        first.type("ghbdtn")
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        let newWord = try rig.request(rig.enToRu)
        XCTAssertFalse(newWord.reconvert)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(newWord, direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(first.text, "ghbdtn привет")

        first.clock += 2 // pause without clearing the confirmed edit state
        let selected = "ghbdtn MacSwitcher"
        first.type(" " + selected) // same field; user later selects this complete fragment
        let selectedStart = first.text.utf16.count - selected.utf16.count
        first.caret = selectedStart
        first.selection = selected.utf16.count
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(first.text, "ghbdtn привет привет MacSwitcher")

        rig.sourceID = rig.enToRu.sourceLayoutID // an explicit solo switch before new EN input
        first.type(" ghbd")
        rig.monitor.handleKeyDown(keyCode: KC.space, flags: [],
            renderedSourceLayoutID: rig.enToRu.sourceLayoutID)
        try rig.type("ghbd", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(first.text, "ghbdtn привет привет MacSwitcher прив")
        first.type("ет")
        try rig.type("ет", source: rig.ruToEn.sourceLayoutID)
        rig.sourceID = rig.ruToEn.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.ruToEn), direction: rig.ruToEn).outcome,
            .confirmed(resultID: rig.ruToEn.targetLayoutID))
        XCTAssertEqual(first.text, "ghbdtn привет привет MacSwitcher ghbdtn",
            "A continuation after selection remains part of the same verified word")

        // A user click changes the AX field; the real monitor resets gesture
        // buffers for that explicit focus change, while the converter is shared.
        rig.frontField = second
        rig.monitor.resetCombinedShift()
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(second.text, "привет")
        XCTAssertEqual(first.text, "ghbdtn привет привет MacSwitcher ghbdtn")
    }

    @MainActor
    func testUnknownPostQueueKeepsOriginalAndRefusesBlindRepeat() throws {
        let field = Field(pid: 5103, text: "ghbdtn")
        field.dropInsertion = true
        let rig = try Rig(fields: [field])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        let result = rig.run(try rig.request(rig.enToRu), direction: rig.enToRu)
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(rig.sourceRequests, 0)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: field.focus()))
        XCTAssertEqual(rig.converter.unconfirmedOriginals.first?.text, "ghbdtn")

        rig.converter.clearState()
        field.clock += 5
        _ = rig.run(try rig.request(rig.enToRu), direction: rig.enToRu)
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(rig.converter.unconfirmedOriginals.first?.text, "ghbdtn")
    }

    @MainActor
    func testUnknownObservedResultRequiresExplicitExactSelectionThenFreshWordWorks() throws {
        let field = Field(pid: 5113, text: "ghbdtn")
        let rig = try Rig(fields: [field])
        rig.reportWrongCaretAfterText = true
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: field.focus()))
        XCTAssertEqual(rig.converter.unconfirmedOriginals.first?.text, "ghbdtn")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(field.text, "привет", "Unicode arrived; only the caret ACK was unavailable")

        // A fresh observation now reports the actual result/caret. This does
        // not by itself authorize recovery from a collapsed caret.
        rig.reportWrongCaretAfterText = false
        field.selection = 0
        rig.sourceID = rig.ruToEn.targetLayoutID // first solo of the next double
        XCTAssertEqual(rig.run(try rig.request(rig.ruToEn), direction: rig.ruToEn).outcome,
            .stopped, "A collapsed caret cannot recover an uncertain whole-field write")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: field.focus()))

        // The user explicitly selects the exact observed result in the same AX
        // field. Only this fresh selection may restore the retained original.
        field.caret = 0
        field.selection = field.text.utf16.count
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.sourceLayoutID))
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.queuedText, 2)
        XCTAssertFalse(rig.converter.hasUnconfirmedAXEdit(in: field.focus()))

        field.type(" ghbdtn")
        rig.monitor.handleKeyDown(keyCode: KC.space, flags: [],
            renderedSourceLayoutID: rig.enToRu.sourceLayoutID)
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "ghbdtn привет")
        XCTAssertEqual(field.queuedText, 3)
    }

    @MainActor
    func testPrequeueRefusalAndSecureFieldLeaveSourceUntouched() throws {
        let field = Field(pid: 5104, text: "ghbdtn")
        let rig = try Rig(fields: [field])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        field.refuseBeforeQueue = true
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(rig.sourceRequests, 0)

        field.refuseBeforeQueue = false
        field.secure = true
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(rig.sourceRequests, 0)
    }

    @MainActor
    func testUnconfirmedSourceAfterTextAckDoesNotResendUnicode() throws {
        let field = Field(pid: 5105, text: "ghbd")
        let rig = try Rig(fields: [field])
        try rig.type("ghbd", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        rig.sourceOutcome = .unconfirmed
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .sourceNotConfirmed(targetID: rig.enToRu.targetLayoutID,
                sourceOutcome: .unconfirmed))
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(rig.sourceRequests, 1)
        XCTAssertTrue(rig.monitor.hasPendingInputSourceTransition)
    }

    @MainActor
    func testUnavailableWholeFieldRefusesSelectedEditBeforeUnicode() throws {
        let field = Field(pid: 5106, text: "ghbdtn MacSwitcher")
        field.caret = 0
        field.selection = field.text.utf16.count
        let rig = try Rig(fields: [field])
        rig.sourceID = rig.enToRu.targetLayoutID
        rig.wholeObservationAvailable = false
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.text, "ghbdtn MacSwitcher")
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(rig.sourceRequests, 0)
    }

    @MainActor
    func testWrongSourceBeforeSelectedPreparationRefusesWithoutUnicode() throws {
        let field = Field(pid: 5107, text: "ghbdtn MacSwitcher")
        field.caret = 0
        field.selection = field.text.utf16.count
        let rig = try Rig(fields: [field])
        rig.sourceID = rig.enToRu.sourceLayoutID // external change after first solo Shift
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.text, "ghbdtn MacSwitcher")
        XCTAssertEqual(field.queuedText, 0)
    }

    @MainActor
    func testContinuationAfterManualEditTargetsWholeWord() throws {
        let field = Field(pid: 5108, text: "ghbd")
        let rig = try Rig(fields: [field])
        try rig.type("ghbd", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "прив")

        field.type("ет")
        try rig.type("ет", source: rig.ruToEn.sourceLayoutID)
        rig.sourceID = rig.ruToEn.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.ruToEn), direction: rig.ruToEn).outcome,
            .confirmed(resultID: rig.ruToEn.targetLayoutID))
        XCTAssertEqual(field.text, "ghbdtn", "The continuation belongs to the confirmed word")
    }

    @MainActor
    func testContinuationAfterManualUndoTargetsWholeWord() throws {
        let field = Field(pid: 5109, text: "ghbd")
        let rig = try Rig(fields: [field])
        try rig.type("ghbd", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        rig.sourceID = rig.ruToEn.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.ruToEn), direction: rig.ruToEn).outcome,
            .confirmed(resultID: rig.ruToEn.targetLayoutID))
        XCTAssertEqual(field.text, "ghbd")

        field.type("tn")
        try rig.type("tn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "привет", "Undo must not turn continuation into an isolated suffix")
    }

    @MainActor
    func testSoloShiftIsImmediateAndSecondTapKeepsOriginalDirection() throws {
        let rig = try Rig(fields: [Field(pid: 5111, text: "")])
        var gesture = CombinedShiftGesture()
        gesture.press(.left, at: 0, context: rig.enToRu)
        XCTAssertEqual(gesture.release(.left, at: 20_000_000), .switchLayout(rig.enToRu))
        gesture.press(.right, at: 95_000_000, context: rig.ruToEn)
        XCTAssertEqual(gesture.release(.right, at: 115_000_000), .convert(rig.enToRu))

        gesture.press(.right, at: 1_000_000_000, context: rig.ruToEn)
        XCTAssertEqual(gesture.release(.right, at: 1_020_000_000), .switchLayout(rig.ruToEn))
        gesture.press(.left, at: 1_500_000_000, context: rig.enToRu)
        XCTAssertEqual(gesture.release(.left, at: 1_520_000_000), .switchLayout(rig.enToRu),
            "A slow repeat is another solo source switch")
    }

    func testBasePredictionWaitsForContextAndProtectsTechnicalInput() {
        let lexicon = PredictionLexicon(wordsByLanguage: [
            "ru": ["привет": 1_000_000, "думаю": 800_000, "а": 8_000_000],
            "en": ["hello": 900_000, "press": 500_000, "f": 20_000]
        ])
        let engine = PredictionEngine(lexicon: lexicon)
        XCTAssertEqual(engine.evaluate(suffix: "ghbd", sourceLanguage: "en")?.replacementSuffix, "прив")
        XCTAssertNil(engine.evaluate(suffix: "ghb", sourceLanguage: "en"))
        XCTAssertNil(engine.evaluate(suffix: "f", sourceLanguage: "en"))
        XCTAssertNil(engine.evaluate(suffix: "f ", sourceLanguage: "en", atBoundary: true))
        XCTAssertEqual(engine.evaluate(suffix: "f привет", sourceLanguage: "ru")?.replacementSuffix,
            "а привет")
        XCTAssertNil(engine.evaluate(suffix: "f привет", sourceLanguage: "ru",
            precedingWords: ["press"]))
        XCTAssertNil(engine.evaluate(suffix: "hello", sourceLanguage: "en", atBoundary: true))
        for protected in ["API", "MacSwitcher", "iPhone", "/tmp/ghbdtn", "foo.com",
                          "user@example.com", "ghbdtn_foo"] {
            XCTAssertNil(engine.evaluate(suffix: protected, sourceLanguage: "en", atBoundary: true),
                protected)
        }
    }

    @MainActor
    func testAutomaticOwnerSequenceUsesProductionCoordinatorAndContinuesAcrossWords() throws {
        let rig = try AutoRig()
        _ = rig.coordinator
        rig.deliver("MacSwitcher ", source: rig.en)
        rig.settle()
        XCTAssertEqual(rig.field.text, "MacSwitcher ")
        XCTAssertEqual(rig.field.queuedText, 0)

        rig.deliverPhysicalEnglishKeys("levf.")
        rig.settle()
        rig.deliver(" ")
        rig.settle()
        XCTAssertEqual(rig.field.text, "MacSwitcher думаю ")
        XCTAssertEqual(rig.sourceID, rig.ru)

        rig.deliverPhysicalEnglishKeys("xnj-nj")
        rig.settle()
        rig.deliver(" ")
        rig.settle()
        XCTAssertEqual(rig.field.text, "MacSwitcher думаю что-то ")

        rig.deliverPhysicalEnglishKeys("nfrjt")
        rig.settle()
        XCTAssertEqual(rig.field.text, "MacSwitcher думаю что-то такое")
        XCTAssertEqual(rig.field.queuedText, 1)
        XCTAssertFalse(rig.applied.isEmpty)
    }

    @MainActor
    func testEarlyAutomaticMistakeCanBeUndoneAndWordContinues() throws {
        let rig = try AutoRig()
        _ = rig.coordinator
        rig.deliver("ghbd", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "прив")
        XCTAssertEqual(rig.sourceID, rig.ru)

        XCTAssertEqual(try rig.undoByDoubleShift().outcome,
            .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.text, "ghbd")
        rig.deliver("tn", source: rig.en)
        rig.settle()
        XCTAssertEqual(rig.field.text, "привет",
            "The confirmed undo must seed the following prediction with its full word")
    }

    @MainActor
    func testDoubleShiftRefusesAutomaticUndoWhenEarlierFieldTextChanged() throws {
        let rig = try AutoRig()
        _ = rig.coordinator
        rig.deliver("X ", source: rig.en)
        rig.deliver("ghbd", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "X прив")
        let queuedBefore = rig.field.queuedText

        rig.field.text = "Y прив" // Same suffix, caret and revision; whole field changed externally.
        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .stopped)
        XCTAssertEqual(rig.field.text, "Y прив")
        XCTAssertEqual(rig.field.queuedText, queuedBefore)
    }

    @MainActor
    func testConfirmedAutomaticSingleLetterUndoEmitsOriginAndContinuesEnglish() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")
        XCTAssertEqual(rig.sourceID, rig.ru)

        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.text, "f")
        XCTAssertEqual(rig.confirmedAutoUndos.map(\.original), ["f"])
        XCTAssertEqual(rig.confirmedAutoUndos.map(\.replacement), ["а"])

        rig.deliver("oo", source: rig.en)
        rig.settle()
        XCTAssertEqual(rig.field.text, "foo")
        XCTAssertEqual(rig.confirmedAutoUndos.count, 1)
    }

    @MainActor
    func testConfirmedAutomaticUndoSuppressesOnlyOneIdenticalRetry() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")
        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.queuedText, 2)

        rig.field.text = ""
        rig.field.caret = 0
        rig.monitor.resetPredictionContext()
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .suppressed)
        XCTAssertEqual(rig.field.text, "f")
        XCTAssertEqual(rig.field.queuedText, 2)

        rig.field.text = ""
        rig.field.caret = 0
        rig.monitor.resetPredictionContext()
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")
        XCTAssertEqual(rig.field.queuedText, 3)
    }

    @MainActor
    func testAutomaticUndoRefusesWrongSourceAfterFirstSoloShift() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")
        let queuedBefore = rig.field.queuedText

        XCTAssertEqual(try rig.undoByDoubleShift(sourceAfterFirst: rig.ru).outcome, .stopped)
        XCTAssertEqual(rig.field.text, "а")
        XCTAssertEqual(rig.field.queuedText, queuedBefore)
        XCTAssertTrue(rig.confirmedAutoUndos.isEmpty)
    }

    @MainActor
    func testFirstSoloTISNotificationPreservesReceiptForSecondShift() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")
        let beforeSession = rig.monitor.predictionSessionID

        XCTAssertEqual(try rig.undoByDoubleShift(notificationAfterFirst: rig.en).outcome,
            .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.monitor.predictionSessionID, beforeSession,
            "A matched first-solo source notification must not reset the prediction session")
        XCTAssertEqual(rig.field.text, "f")
        XCTAssertEqual(rig.confirmedAutoUndos.count, 1)
    }

    @MainActor
    func testUnrelatedTISNotificationStillInvalidatesAutomaticUndo() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        let beforeSession = rig.monitor.predictionSessionID
        let unrelated = "test.unrelated.layout"

        XCTAssertEqual(try rig.undoByDoubleShift(sourceAfterFirst: unrelated,
            notificationAfterFirst: unrelated).outcome, .stopped)
        XCTAssertNotEqual(rig.monitor.predictionSessionID, beforeSession)
        XCTAssertEqual(rig.field.text, "а")
        XCTAssertEqual(rig.field.queuedText, 1)
        XCTAssertTrue(rig.confirmedAutoUndos.isEmpty)
    }

    @MainActor
    func testLateSourceNotificationsPreserveConfirmedUndoSession() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        let afterAutoSession = rig.monitor.predictionSessionID
        rig.monitor.resetLineBuffer(sourceLayoutID: rig.ru) // Late TIS read after auto ACK.
        XCTAssertEqual(rig.monitor.predictionSessionID, afterAutoSession)

        XCTAssertEqual(try rig.undoByDoubleShift(notificationAfterFirst: rig.en).outcome,
            .confirmed(resultID: rig.en))
        let afterUndoSession = rig.monitor.predictionSessionID
        rig.monitor.resetLineBuffer(sourceLayoutID: rig.en) // Late TIS read after reverse ACK.
        XCTAssertEqual(rig.monitor.predictionSessionID, afterUndoSession)
        XCTAssertEqual(rig.field.text, "f")
    }

    @MainActor
    func testExpiredToastStillAllowsSingleGestureUndoAfterPause() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.correctionNotices.last)
        rig.receiptClock += 16_000_000_000

        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .refused = result else { XCTFail("Expired toast should be refused"); return }
        }
        XCTAssertEqual(rig.field.text, "а")
        XCTAssertEqual(try rig.undoByDoubleShift(notificationAfterFirst: rig.en).outcome,
            .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.text, "f")
        XCTAssertEqual(rig.confirmedAutoUndos.count, 1)
    }

    @MainActor
    func testUnknownReceiptUndoCannotQueueASecondBlindReverseWrite() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")
        rig.field.dropInsertion = true

        XCTAssertEqual(try rig.undoByDoubleShift(notificationAfterFirst: rig.en).outcome, .stopped)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: rig.field.focus()))
        let queuedAfterUnknown = rig.field.queuedText
        XCTAssertEqual(queuedAfterUnknown, 2)
        rig.field.dropInsertion = false

        _ = try rig.undoByDoubleShift(direction: CombinedShiftContext(
            sourceLayoutID: rig.en, targetLayoutID: rig.ru))
        XCTAssertEqual(rig.field.queuedText, queuedAfterUnknown)
        XCTAssertTrue(rig.confirmedAutoUndos.isEmpty)
    }

    @MainActor
    func testAutomaticUndoDoesNotOfferExceptionWhenSourceCommitFails() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")
        rig.undoSourceOutcome = .refused

        XCTAssertEqual(try rig.undoByDoubleShift().outcome,
            .sourceNotConfirmed(targetID: rig.en, sourceOutcome: .refused))
        XCTAssertEqual(rig.field.text, "f")
        XCTAssertEqual(rig.field.queuedText, 2)
        XCTAssertTrue(rig.confirmedAutoUndos.isEmpty)
    }

    @MainActor
    func testAutomaticUndoCanBeManuallyRedoneAndUndoneWithoutTyping() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")

        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.text, "f")
        XCTAssertEqual(try rig.undoByDoubleShift(direction: CombinedShiftContext(
            sourceLayoutID: rig.en, targetLayoutID: rig.ru)).outcome,
            .confirmed(resultID: rig.ru))
        XCTAssertEqual(rig.field.text, "а")
        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.text, "f")
        XCTAssertEqual(rig.confirmedAutoUndos.count, 1)

        rig.deliver(" hello", source: rig.en)
        rig.settle()
        XCTAssertEqual(rig.field.text, "f hello")
    }

    @MainActor
    func testMultiCharacterAutomaticUndoCanCycleThroughManualRedo() throws {
        let rig = try AutoRig()
        _ = rig.coordinator
        rig.deliver("ghbd", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "прив")

        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.text, "ghbd")
        XCTAssertEqual(try rig.undoByDoubleShift(direction: CombinedShiftContext(
            sourceLayoutID: rig.en, targetLayoutID: rig.ru)).outcome,
            .confirmed(resultID: rig.ru))
        XCTAssertEqual(rig.field.text, "прив")
        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.text, "ghbd")
        XCTAssertEqual(rig.confirmedAutoUndos.count, 1)
    }

    @MainActor
    func testToastUndoCanBeManuallyRedoneWithoutNewTyping() throws {
        let rig = try AutoRig()
        _ = rig.coordinator
        rig.deliver("ghbd", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "прив")
        let notice = try XCTUnwrap(rig.correctionNotices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Expected confirmed toast undo"); return }
        }
        XCTAssertEqual(rig.field.text, "ghbd")

        XCTAssertEqual(try rig.undoByDoubleShift(direction: CombinedShiftContext(
            sourceLayoutID: rig.en, targetLayoutID: rig.ru)).outcome,
            .confirmed(resultID: rig.ru))
        XCTAssertEqual(rig.field.text, "прив")
        XCTAssertTrue(rig.confirmedAutoUndos.isEmpty,
            "A manual redo after toast undo is not a second automatic undo")
    }

    @MainActor
    func testSelectedOwnerPhrasePreservesNameAndHyphen() throws {
        let field = Field(pid: 5112, text: "MacSwitcher levf. xnj-nj nfrjt")
        field.caret = 0
        field.selection = field.text.utf16.count
        let rig = try Rig(fields: [field])
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "MacSwitcher думаю что-то такое")
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testPastedWholeLastWordUsesVerifiedFieldWhenTypingBufferIsEmpty() throws {
        let field = Field(pid: 5191, text: "ghbdtn")
        let rig = try Rig(fields: [field])
        rig.monitor.resetCombinedShift()
        rig.sourceID = rig.enToRu.targetLayoutID
        let request = try rig.request(rig.enToRu)
        XCTAssertTrue(request.wordKeys.isEmpty)
        XCTAssertTrue(request.prevWordKeys.isEmpty)
        XCTAssertFalse(request.reconvert)
        XCTAssertEqual(rig.run(request, direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "привет")
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testNativeSelectionUsesPreparedLocalWordEvidence() throws {
        let field = Field(pid: 5192, text: "ghbdtn MacSwitcher")
        field.caret = 0
        field.selection = field.text.utf16.count
        let rig = try Rig(fields: [field])
        var lookups = 0
        rig.selectionKnownWord = { word, language in
            lookups += 1
            return language == "en" && word == "ghbdtn"
        }
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .stopped)
        XCTAssertGreaterThan(lookups, 0, "Native selection must use prepared local evidence")
        XCTAssertEqual(field.text, "ghbdtn MacSwitcher")
        XCTAssertEqual(field.queuedText, 0)
    }

    @MainActor
    func testChangedRussianTokenChoosesRussianDespiteLongUnchangedBrand() throws {
        Dict.warmUp() // isolate result-source policy; the slow-policy test covers lease timing
        let field = Field(pid: 5114, text: "ghbdtn MacSwitcher")
        field.caret = 0
        field.selection = field.text.utf16.count
        let rig = try Rig(fields: [field])
        rig.sourceID = rig.enToRu.targetLayoutID
        let result = rig.run(try rig.request(rig.enToRu), direction: rig.enToRu)
        XCTAssertEqual(field.text, "привет MacSwitcher")
        XCTAssertEqual(result.outcome, .confirmed(resultID: rig.enToRu.targetLayoutID),
            "Unchanged MacSwitcher must not outweigh the corrected Russian word")
    }

    @MainActor
    func testChangedEnglishTokenChoosesEnglishDespiteLongUnchangedRussianWord() throws {
        Dict.warmUp()
        let field = Field(pid: 5115, text: "руддщ привет")
        field.caret = 0
        field.selection = field.text.utf16.count
        let rig = try Rig(fields: [field])
        rig.sourceID = rig.ruToEn.targetLayoutID
        let result = rig.run(try rig.request(rig.ruToEn), direction: rig.ruToEn)
        XCTAssertEqual(field.text, "hello привет")
        XCTAssertEqual(result.outcome, .confirmed(resultID: rig.ruToEn.targetLayoutID),
            "Unchanged Russian neighbour must not outweigh the corrected English word")
    }
}
