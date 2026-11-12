import ApplicationServices
import XCTest
@testable import RuSwitcher

/// Exercises the same lease/edit/source transaction that AppDelegate calls.
/// Only AX, HID delivery and TIS are replaced with synthetic boundaries.
final class ProductionCombinedShiftTransactionTests: XCTestCase {
    typealias Field = ProductionCombinedShiftEditingTests.Field

    private final class ArchiveProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var state = (enabled: false, lease: false, fail: false, calls: 0, sawLease: false)
        func configure(enabled: Bool? = nil, lease: Bool? = nil, fail: Bool? = nil) {
            lock.lock(); defer { lock.unlock() }
            if let enabled { state.enabled = enabled }
            if let lease { state.lease = lease }
            if let fail { state.fail = fail }
        }
        var enabled: Bool { lock.lock(); defer { lock.unlock() }; return state.enabled }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return state.calls }
        var sawLease: Bool { lock.lock(); defer { lock.unlock() }; return state.sawLease }
        func save(_ sources: [RecoveryArchive.Source], in directory: URL) throws -> RecoveryArchive.Receipt {
            lock.lock()
            state.calls += 1
            state.sawLease = state.sawLease || state.lease
            let fail = state.fail
            lock.unlock()
            if fail { throw RecoveryArchive.Failure.syncFailed }
            return try RecoveryArchive.saveVerified(sources, in: directory)
        }
    }

    private final class HeadroomValidationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var capacityReleased = false

        var validationCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func releaseCapacity() { lock.lock(); capacityReleased = true; lock.unlock() }
        func validate(_ id: UUID, _ receipt: RecoveryArchive.Receipt) throws -> String {
            lock.lock()
            calls += 1
            let unexpectedRepeat = calls > 9 && !capacityReleased
            lock.unlock()
            if unexpectedRepeat { throw RecoveryArchive.Failure.verificationFailed }
            return try RecoveryArchive.original(id: id, receipt: receipt)
        }
    }

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
        var gestureHostPID: Int32?
        var currentTargetPID: (() -> Int32?)?

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
        }, automaticRoute: { _, _, _ in .nativeVerified })

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

        func request(_ direction: CombinedShiftContext,
                     firstFocus: CombinedShiftFocus? = nil) throws -> CombinedShiftRequest {
            let contexts = [enToRu.sourceLayoutID: enToRu, ruToEn.sourceLayoutID: ruToEn]
            _ = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .switchLayout(direction),
                frontProcessID: gestureHostPID ?? frontField.pid, focus: firstFocus ?? frontField.focus(),
                contextForSource: { contexts[$0] }))
            return try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .convert(direction),
                frontProcessID: gestureHostPID ?? frontField.pid, focus: frontField.focus(),
                contextForSource: { contexts[$0] }))
        }

        func run(_ request: CombinedShiftRequest,
                 direction: CombinedShiftContext) -> CombinedShiftTransaction.Result {
            let execution = CombinedShiftExecutionContext(focus: request.focus!,
                inputRevision: request.inputRevision,
                currentInputRevision: { [unowned self] in monitor.inputRevision })
            if gestureHostPID != nil && !execution.isValid() {
                // AppDelegate.runNativeCombinedShift performs this entry check
                // before calling the production transaction.
                return .init(outcome: .stopped, failureNotice: .noSafeEdit,
                    pendingSourceTargetID: nil, confirmedAutomaticUndo: nil)
            }
            let platform = CombinedShiftTransaction.Platform(
                currentSourceID: { [unowned self] in sourceID },
                frontProcessID: { [unowned self] in
                    currentTargetPID.map { $0() } ?? frontField.pid
                },
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
        let suppliedLexicon: PredictionLexicon?

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
                platform: platform, engine: PredictionEngine(lexicon: suppliedLexicon ?? lexicon),
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

        init(lexicon: PredictionLexicon? = nil) throws {
            suppliedLexicon = lexicon
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
    func testOverlayBoundRepeatedManualEditsAndChangedTargetRefuseBeforeQueue() throws {
        let hostPID: Int32 = 6201
        let overlayPID: Int32 = 6202
        let field = Field(pid: overlayPID, text: "ghbdtn")
        let rig = try Rig(fields: [field])
        let window = SearchOverlayTargetPolicy.WindowEvidence(processID: overlayPID,
            windowID: 8101, bundleID: "com.example.search", ownerName: "Search")
        var frontPID = hostPID
        var systemPID = overlayPID
        var systemElement = field.element
        var visibleWindows = [window]
        let probe = SearchOverlayTarget.Probe(now: { 0 }, frontPID: { frontPID },
            bundleID: { _ in "com.example.search" },
            systemFocus: { _ in (systemPID, systemElement) },
            directFocus: { _, _ in CombinedShiftFocus(processID: overlayPID, element: field.element) },
            editable: { _, _ in true }, windows: { _ in visibleWindows },
            focusedWindowBounds: { _, _ in nil }, selection: { _, _ in field.selectedRange() })
        let initialCapture = try XCTUnwrap({ () -> CombinedShiftFocus? in
            if case .verified(let focus) = SearchOverlayTarget.capture(hostPID: hostPID, probe: probe) {
                return focus
            }
            return nil
        }())
        let initialBinding = try XCTUnwrap(initialCapture.searchOverlay)
        rig.gestureHostPID = hostPID
        rig.currentTargetPID = { [probe] in
            SearchOverlayTarget.currentProcessID(for: initialBinding, probe: probe)
        }
        func boundFocus() throws -> CombinedShiftFocus {
            let captured = try XCTUnwrap({ () -> CombinedShiftFocus? in
                if case .verified(let focus) = SearchOverlayTarget.capture(hostPID: hostPID, probe: probe) {
                    return focus
                }
                return nil
            }())
            let binding = try XCTUnwrap(captured.searchOverlay)
            return CombinedShiftFocus(processID: captured.processID, element: captured.element,
                initialSelection: captured.initialSelection,
                fieldBoundary: CombinedShiftFieldBoundary(validationFailure: {
                    guard field.valid,
                          SearchOverlayTarget.isCurrent(captured, binding: binding, probe: probe) else {
                        return .focusChanged
                    }
                    return nil
                }, selectionRange: { field.selectedRange() }, text: { field.substring($0) }),
                searchOverlay: binding)
        }
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu, firstFocus: boundFocus()),
            direction: rig.enToRu).outcome, .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "привет")

        rig.sourceID = rig.ruToEn.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.ruToEn, firstFocus: boundFocus()),
            direction: rig.ruToEn).outcome, .confirmed(resultID: rig.ruToEn.targetLayoutID))
        XCTAssertEqual(field.text, "ghbdtn")
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu, firstFocus: boundFocus()),
            direction: rig.enToRu).outcome, .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "привет")

        field.type(" ghbdtn")
        rig.monitor.handleKeyDown(keyCode: KC.space, flags: [],
            renderedSourceLayoutID: rig.enToRu.sourceLayoutID)
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu, firstFocus: boundFocus()),
            direction: rig.enToRu).outcome, .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "привет привет")

        let queued = field.queuedText
        let disappearing = try rig.request(rig.ruToEn, firstFocus: boundFocus())
        visibleWindows = []
        XCTAssertEqual(rig.run(disappearing, direction: rig.ruToEn).outcome, .stopped)
        XCTAssertEqual(field.queuedText, queued)
        visibleWindows = [window]
        let changedHost = try rig.request(rig.ruToEn, firstFocus: boundFocus())
        frontPID = 9999
        XCTAssertEqual(rig.run(changedHost, direction: rig.ruToEn).outcome, .stopped)
        XCTAssertEqual(field.queuedText, queued)
        frontPID = hostPID
        let changedFocus = try rig.request(rig.ruToEn, firstFocus: boundFocus())
        systemPID = hostPID
        systemElement = AXUIElementCreateApplication(hostPID)
        XCTAssertEqual(rig.run(changedFocus, direction: rig.ruToEn).outcome, .stopped)
        XCTAssertEqual(field.queuedText, queued)
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
    func testVerifiedArchiveReleasesOnlyBackedRAMCapacityAndKeepsExactFieldLocked() throws {
        let fields = (0..<12).map { Field(pid: 5700 + Int32($0), text: "ghbdtn") }
        fields.forEach { $0.dropInsertion = true }
        let rig = try Rig(fields: fields)
        for field in fields.prefix(8) {
            rig.frontField = field
            rig.monitor.resetCombinedShift()
            try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
            rig.sourceID = rig.enToRu.targetLayoutID
            XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
            XCTAssertEqual(field.queuedText, 1)
        }
        XCTAssertEqual(rig.converter.unconfirmedOriginals.count, 8)
        rig.frontField = fields[8]
        rig.monitor.resetCombinedShift()
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(fields[8].queuedText, 0)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originals = rig.converter.unconfirmedOriginals.map { RecoveryArchive.Source(id: $0.id, text: $0.text) }
        XCTAssertThrowsError(try RecoveryArchive.saveVerified(originals, in: directory,
            syncer: { _, isDirectory in
                if !isDirectory { throw RecoveryArchive.Failure.syncFailed }
            }))
        XCTAssertEqual(rig.converter.unconfirmedOriginals.count, 8)
        XCTAssertEqual(rig.converter.archivedOriginals.count, 0)
        let receipt = try RecoveryArchive.saveVerified(originals, in: directory)
        XCTAssertTrue(rig.converter.markArchived(receipt))
        let oldest = try XCTUnwrap(rig.converter.backedOriginals.first)
        XCTAssertEqual(try RecoveryArchive.original(id: oldest.id, receipt: oldest.archive), oldest.text)
        XCTAssertTrue(rig.converter.evictValidatedBacking(id: oldest.id, receipt: oldest.archive))
        let unrelated = try RecoveryArchive.saveVerified([.init(id: UUID(), text: "synthetic")], in: directory)
        XCTAssertFalse(rig.converter.markArchived(unrelated))
        rig.converter.clearState()
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: fields[0].focus()))
        rig.frontField = fields[8]
        rig.monitor.resetCombinedShift()
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(fields[8].queuedText, 1)
        XCTAssertEqual(rig.converter.unconfirmedOriginals.count, 8)
        XCTAssertEqual(rig.converter.archivedOriginals.count, 1)
        XCTAssertEqual(try RecoveryArchive.original(id: rig.converter.archivedOriginals[0].id,
            receipt: rig.converter.archivedOriginals[0].archive), "ghbdtn")
        rig.frontField = fields[0]
        rig.monitor.resetCombinedShift()
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(fields[0].queuedText, 1)
        for field in fields[9...] {
            let backed = try XCTUnwrap(rig.converter.backedOriginals.first)
            XCTAssertEqual(try RecoveryArchive.original(id: backed.id, receipt: backed.archive), backed.text)
            XCTAssertTrue(rig.converter.evictValidatedBacking(id: backed.id, receipt: backed.archive))
            rig.frontField = field
            rig.monitor.resetCombinedShift()
            try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
            rig.sourceID = rig.enToRu.targetLayoutID
            XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
            XCTAssertEqual(field.queuedText, 1)
        }
        XCTAssertEqual(rig.converter.unconfirmedOriginals.count, 8)
        XCTAssertEqual(rig.converter.archivedOriginals.count, 4)
        XCTAssertEqual(Set(rig.converter.archivedOriginals.map(\.id)).count, 4)
        for original in rig.converter.archivedOriginals {
            XCTAssertEqual(try RecoveryArchive.original(id: original.id, receipt: original.archive), "ghbdtn")
        }
        rig.converter.releaseArchivedLocks(forTerminatedProcessID: fields[0].pid)
        XCTAssertEqual(rig.converter.archivedOriginals.count, 3)
        XCTAssertFalse(rig.converter.hasUnconfirmedAXEdit(in: fields[0].focus()))
        XCTAssertEqual(try RecoveryArchive.original(id: originals[0].id, receipt: receipt), "ghbdtn")
    }

    @MainActor
    func testAutomaticArchiveRunsAfterLeaseCoalescesAndPreservesRAMOnFailure() async throws {
        let field = Field(pid: 5720, text: "ghbdtn")
        let later = Field(pid: 5723, text: "ghbdtn")
        field.dropInsertion = true
        later.dropInsertion = true
        let rig = try Rig(fields: [field, later])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(rig.converter.unbackedOriginals.count, 1)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ArchiveProbe()
        let controller = RecoveryArchiveController(converter: rig.converter,
            enabled: { probe.enabled }, directory: { directory }, save: { try probe.save($0, in: $1) })
        controller.scheduleAutomaticAfterCurrentEvent()
        await Task.yield()
        XCTAssertEqual(probe.calls, 0, "Default-off must not export")

        probe.configure(enabled: true, lease: true, fail: true)
        let failed = expectation(description: "automatic export failure")
        controller.onFailure = { manual, _ in XCTAssertFalse(manual); failed.fulfill() }
        controller.scheduleAutomaticAfterCurrentEvent()
        controller.scheduleAutomaticAfterCurrentEvent()
        probe.configure(lease: false)
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(probe.calls, 1, "Duplicate pending requests must not create duplicate exports")
        XCTAssertFalse(probe.sawLease, "Archive I/O must start after the input lease")
        XCTAssertEqual(rig.converter.unbackedOriginals.count, 1)

        probe.configure(fail: false)
        let saved = expectation(description: "explicit retry saves")
        controller.onSaved = { saved.fulfill() }
        controller.requestManual() // bypass automatic failure backoff
        await fulfillment(of: [saved], timeout: 3)
        XCTAssertEqual(rig.converter.unbackedOriginals.count, 0)
        XCTAssertEqual(rig.converter.unconfirmedOriginals.count, 1,
            "A newly backed field remains available for explicit reconversion")
        probe.configure(enabled: false)
        rig.frontField = later
        rig.monitor.resetCombinedShift()
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        controller.scheduleAutomaticAfterCurrentEvent()
        await Task.yield()
        XCTAssertEqual(probe.calls, 2, "Opt-out prevents new automatic exports")
        XCTAssertEqual(rig.converter.unbackedOriginals.count, 1)
    }

    @MainActor
    func testAutomaticArchiveSavesUnknownAddedDuringInFlightExport() async throws {
        let fields = [Field(pid: 5721, text: "ghbdtn"), Field(pid: 5722, text: "ghbdtn")]
        fields.forEach { $0.dropInsertion = true }
        let rig = try Rig(fields: fields)
        rig.frontField = fields[0]
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ArchiveProbe()
        probe.configure(enabled: true)
        let entered = expectation(description: "first archive started")
        let completed = expectation(description: "both archives completed")
        completed.expectedFulfillmentCount = 2
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let controller = RecoveryArchiveController(converter: rig.converter,
            enabled: { probe.enabled }, directory: { directory }, save: { sources, url in
                if probe.calls == 0 {
                    entered.fulfill()
                    _ = gate.wait(timeout: .now() + 3)
                }
                return try probe.save(sources, in: url)
            })
        controller.onSaved = { completed.fulfill() }
        controller.scheduleAutomaticAfterCurrentEvent()
        await fulfillment(of: [entered], timeout: 3)
        rig.frontField = fields[1]
        rig.monitor.resetCombinedShift()
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        controller.scheduleAutomaticAfterCurrentEvent()
        gate.signal()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(probe.calls, 2)
        XCTAssertTrue(rig.converter.unbackedOriginals.isEmpty)
        XCTAssertEqual(rig.converter.unconfirmedOriginals.count, 2)
    }

    @MainActor
    func testAutomaticArchiveRetriesOnlyOnceAndOptOutCancelsPendingRetry() async throws {
        let field = Field(pid: 5724, text: "ghbdtn")
        field.dropInsertion = true
        let rig = try Rig(fields: [field])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ArchiveProbe()
        probe.configure(enabled: true, fail: true)
        let retried = expectation(description: "one automatic retry")
        retried.expectedFulfillmentCount = 2
        let controller = RecoveryArchiveController(converter: rig.converter,
            enabled: { probe.enabled }, directory: { directory },
            save: { try probe.save($0, in: $1) }, retryDelay: 0.03)
        controller.onFailure = { _, _ in retried.fulfill() }
        controller.requestAutomatic()
        await fulfillment(of: [retried], timeout: 3)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(rig.converter.unbackedOriginals.count, 1)

        let cancelProbe = ArchiveProbe()
        cancelProbe.configure(enabled: true, fail: true)
        let firstFailure = expectation(description: "failure before opt-out")
        let cancellation = RecoveryArchiveController(converter: rig.converter,
            enabled: { cancelProbe.enabled }, directory: { directory },
            save: { try cancelProbe.save($0, in: $1) }, retryDelay: 0.03)
        cancellation.onFailure = { _, _ in firstFailure.fulfill() }
        cancellation.requestAutomatic()
        await fulfillment(of: [firstFailure], timeout: 3)
        cancelProbe.configure(enabled: false)
        cancellation.settingChanged(false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(cancelProbe.calls, 1)
    }

    @MainActor
    func testControllerPreparesHeadroomOnlyAfterValidatingArchiveOffInputPath() async throws {
        let fields = (0..<8).map { Field(pid: 5740 + Int32($0), text: "ghbdtn") }
        fields.forEach { $0.dropInsertion = true }
        let rig = try Rig(fields: fields)
        for field in fields {
            rig.frontField = field
            rig.monitor.resetCombinedShift()
            try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
            rig.sourceID = rig.enToRu.targetLayoutID
            XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = expectation(description: "verified backed headroom")
        let controller = RecoveryArchiveController(converter: rig.converter,
            enabled: { false }, directory: { directory })
        controller.onHeadroomPrepared = { prepared.fulfill() }
        controller.requestManual()
        await fulfillment(of: [prepared], timeout: 3)
        XCTAssertEqual(rig.converter.unconfirmedOriginals.count, 7)
        XCTAssertEqual(rig.converter.archivedOriginals.count, 1)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: fields[0].focus()))
        let alreadySaved = expectation(description: "existing archive validated without reexport")
        controller.onSaved = { alreadySaved.fulfill() }
        controller.requestManual()
        await fulfillment(of: [alreadySaved], timeout: 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    @MainActor
    func testControllerStopsAtArchivedFieldLimitAndResumesAfterCapacityRelease() async throws {
        let fields = (0..<264).map { Field(pid: 5800 + Int32($0), text: "ghbdtn") }
        fields.forEach { $0.dropInsertion = true }
        let rig = try Rig(fields: fields)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockDirectory = directory.appendingPathComponent("locks")
        let finalDirectory = directory.appendingPathComponent("final")

        func retainUnknown(_ field: Field) throws {
            rig.frontField = field
            rig.monitor.resetCombinedShift()
            try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
            rig.sourceID = rig.enToRu.targetLayoutID
            XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
            XCTAssertEqual(field.queuedText, 1)
        }

        for field in fields.prefix(8) { try retainUnknown(field) }
        let firstBatch = rig.converter.unbackedOriginals.map { RecoveryArchive.Source(id: $0.id, text: $0.text) }
        XCTAssertTrue(rig.converter.markArchived(try RecoveryArchive.saveVerified(firstBatch, in: lockDirectory)))
        for index in 0..<256 {
            if index > 0 {
                try retainUnknown(fields[index + 7])
                let latest = rig.converter.unbackedOriginals.map { RecoveryArchive.Source(id: $0.id, text: $0.text) }
                XCTAssertEqual(latest.count, 1)
                XCTAssertTrue(rig.converter.markArchived(try RecoveryArchive.saveVerified(latest, in: lockDirectory)))
            }
            let oldest = try XCTUnwrap(rig.converter.backedOriginals.first)
            XCTAssertEqual(try RecoveryArchive.original(id: oldest.id, receipt: oldest.archive), oldest.text)
            XCTAssertTrue(rig.converter.evictValidatedBacking(id: oldest.id, receipt: oldest.archive))
        }
        try retainUnknown(fields[263])
        let final = rig.converter.unbackedOriginals.map { RecoveryArchive.Source(id: $0.id, text: $0.text) }
        XCTAssertEqual(final.count, 1)
        XCTAssertTrue(rig.converter.markArchived(try RecoveryArchive.saveVerified(final, in: finalDirectory)))
        XCTAssertEqual(rig.converter.archivedOriginals.count, 256)
        XCTAssertEqual(rig.converter.backedOriginals.count, 8)

        let probe = HeadroomValidationProbe()
        let firstHeadroomRead = expectation(description: "first headroom archive validation")
        let controller = RecoveryArchiveController(converter: rig.converter,
            enabled: { true }, directory: { finalDirectory },
            validate: { id, receipt in
                let text = try probe.validate(id, receipt)
                if probe.validationCalls == 9 { firstHeadroomRead.fulfill() }
                return text
            })
        var preparedCount = 0
        var failureCount = 0
        controller.onHeadroomPrepared = { preparedCount += 1 }
        controller.onFailure = { _, _ in failureCount += 1 }
        controller.requestManual()
        await fulfillment(of: [firstHeadroomRead], timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.validationCalls, 9, "A full archived-field budget must not revalidate the same RAM original")
        XCTAssertEqual(preparedCount, 0, "No capacity was released")
        XCTAssertEqual(failureCount, 0, "A valid archive must not be invalidated by a capacity limit")
        XCTAssertEqual(rig.converter.backedOriginals.count, 8)
        XCTAssertEqual(rig.converter.archivedOriginals.count, 256)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: fields[0].focus()))
        controller.requestAutomatic()
        controller.requestAutomatic()
        XCTAssertEqual(probe.validationCalls, 9, "Automatic polling has no new unsaved source to process")

        rig.converter.releaseArchivedLocks(forTerminatedProcessID: fields[0].pid)
        probe.releaseCapacity()
        let resumed = expectation(description: "headroom prepared after lock release")
        controller.onHeadroomPrepared = { preparedCount += 1; resumed.fulfill() }
        controller.requestManual()
        await fulfillment(of: [resumed], timeout: 5)
        XCTAssertEqual(preparedCount, 1)
        XCTAssertEqual(rig.converter.backedOriginals.count, 7)
        XCTAssertEqual(rig.converter.archivedOriginals.count, 256)
        XCTAssertFalse(rig.converter.hasUnconfirmedAXEdit(in: fields[0].focus()))
    }

    @MainActor
    func testMissingArchiveRevokesBackingButNeverDropsOnlyRAMOriginal() async throws {
        let fields = (0..<8).map { Field(pid: 5760 + Int32($0), text: "ghbdtn") }
        fields.forEach { $0.dropInsertion = true }
        let rig = try Rig(fields: fields)
        for field in fields {
            rig.frontField = field
            rig.monitor.resetCombinedShift()
            try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
            rig.sourceID = rig.enToRu.targetLayoutID
            XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originals = rig.converter.unconfirmedOriginals.map { RecoveryArchive.Source(id: $0.id, text: $0.text) }
        let receipt = try RecoveryArchive.saveVerified(originals, in: directory)
        XCTAssertTrue(rig.converter.markArchived(receipt))
        try FileManager.default.removeItem(at: receipt.file)
        let failed = expectation(description: "manual resave fails")
        let controller = RecoveryArchiveController(converter: rig.converter,
            enabled: { false }, directory: { directory },
            save: { _, _ in throw RecoveryArchive.Failure.writeFailed })
        controller.onFailure = { manual, _ in XCTAssertTrue(manual); failed.fulfill() }
        controller.requestManual()
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(rig.converter.unconfirmedOriginals.count, 8)
        XCTAssertEqual(rig.converter.unbackedOriginals.count, 8)
        XCTAssertTrue(rig.converter.archivedOriginals.isEmpty)
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

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originals = rig.converter.unconfirmedOriginals.map { RecoveryArchive.Source(id: $0.id, text: $0.text) }
        XCTAssertTrue(rig.converter.markArchived(try RecoveryArchive.saveVerified(originals, in: directory)))
        XCTAssertEqual(rig.converter.unconfirmedOriginals.count, 1,
            "A backed fresh field must keep its original in RAM for explicit reconversion")

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
    func testExactRecoveryOfUnknownManualEditAllowsNextAutomaticWord() throws {
        let field = Field(pid: 5114, text: "hello")
        let rig = try Rig(fields: [field])
        let probe = PredictionEvaluationProbe()
        let platform = PredictionCoordinatorPlatform(
            frontmost: { ("com.apple.TextEdit", field.pid) },
            currentLayoutID: { rig.sourceID },
            route: { _, _, _ in .nativeVerified }, deniedApp: { _ in false },
            autoSwitchEnabled: { true }, autoConvertEnabled: { true }, remoteDeferred: { false },
            secureInputActive: { field.secure },
            captureFocus: { pid in pid == field.pid ? field.focus() : nil },
            focusIsCurrent: { focus in
                field.valid && focus.processID == field.pid && CFEqual(focus.element, field.element)
            },
            beginLease: { rig.fence.begin(processID: $0, maximumDuration: 0.250) },
            leaseIsCurrent: { rig.fence.isCurrent($0) },
            leaseRemaining: { rig.fence.remainingDuration($0) },
            finishLease: { rig.fence.finish($0, replayLayoutID: $1) },
            selectSource: { target in rig.sourceID = target; return .confirmed },
            sourceRequestedAt: { DispatchTime.now().uptimeNanoseconds },
            noteUnconfirmedSource: { target, at in
                rig.monitor.noteUnconfirmedInputSource(target, requestedAt: at)
            })
        let coordinator = PredictionCoordinator(monitor: rig.monitor, converter: rig.converter,
            platform: platform, engine: PredictionEngine(lexicon: PredictionLexicon(wordsByLanguage: [
                "en": ["hello": 900_000], "ru": ["привет": 1_000_000]
            ])))
        coordinator.onEvaluationFinished = { id, outcome in probe.finished(id, outcome) }
        rig.monitor.onPredictionInput = { snapshot in
            coordinator.submit(snapshot)
            probe.submitted(coordinator.latestSubmittedEvaluationID)
        }
        rig.monitor.onPredictionInvalidated = { coordinator.invalidate() }

        try rig.type("hello", source: rig.enToRu.sourceLayoutID)
        rig.monitor.recordPredictionText("hello", processID: field.pid, sourceLayoutID: rig.sourceID)
        probe.awaitLatest(expected: .noProposal)
        rig.reportWrongCaretAfterText = true
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.text, "руддщ")
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: field.focus()))

        rig.reportWrongCaretAfterText = false
        field.caret = 0
        field.selection = field.text.utf16.count
        rig.sourceID = rig.ruToEn.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.ruToEn), direction: rig.ruToEn).outcome,
            .confirmed(resultID: rig.ruToEn.targetLayoutID))
        XCTAssertEqual(field.text, "hello")
        XCTAssertFalse(rig.converter.hasUnconfirmedAXEdit(in: field.focus()))

        field.type(" ")
        rig.monitor.recordPredictionText(" ", processID: field.pid, sourceLayoutID: rig.sourceID)
        probe.awaitLatest(expected: .noProposal)
        field.type("ghbd")
        rig.monitor.recordPredictionText("ghbd", processID: field.pid, sourceLayoutID: rig.sourceID)
        probe.awaitLatest(expected: .applied)
        XCTAssertEqual(field.text, "hello прив")
        XCTAssertEqual(field.queuedText, 3, "Unknown, explicit recovery, then one automatic edit")
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
    func testEarlyAutomaticMistakeUndoKeepsContinuationUntilBoundary() throws {
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
        XCTAssertEqual(rig.field.text, "ghbdtn",
            "The explicit undo keeps the current word unchanged until its boundary")
        XCTAssertEqual(rig.sourceID, rig.en)
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
    func testBrandShortWordDoubleShiftUndoSurvivesSpaceBeforeNextRussianWord() throws {
        let rig = try AutoRig(lexicon: PredictionLexicon.bundled())
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("MacSwitcher ", source: rig.en)
        rig.settle()
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "MacSwitcher а")
        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.text, "MacSwitcher f")

        let afterUndo = rig.probe.latestSubmitted
        rig.deliver(" ", source: rig.en)
        XCTAssertEqual(rig.probe.latestSubmitted, afterUndo)
        XCTAssertEqual(rig.field.text, "MacSwitcher f ")
        XCTAssertEqual(rig.sourceID, rig.en)

        rig.deliver("ghbdtn", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "MacSwitcher f привет")
        XCTAssertEqual(rig.sourceID, rig.ru)
    }

    @MainActor
    func testBrandUndoIgnoresContinuationAndFreshShortWordCanApply() throws {
        let rig = try AutoRig(lexicon: PredictionLexicon.bundled())
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("MacSwitcher ", source: rig.en)
        rig.settle()
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .confirmed(resultID: rig.en))

        let afterUndo = rig.probe.latestSubmitted
        rig.deliver("oo", source: rig.en)
        XCTAssertEqual(rig.probe.latestSubmitted, afterUndo)
        XCTAssertEqual(rig.field.text, "MacSwitcher foo")
        rig.deliver(" ", source: rig.en)
        XCTAssertEqual(rig.probe.latestSubmitted, afterUndo)
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "MacSwitcher foo а")
        XCTAssertEqual(rig.sourceID, rig.ru)
    }

    @MainActor
    func testUndoOfBoundaryCorrectionAllowsImmediateNextWord() throws {
        let rig = try AutoRig(lexicon: PredictionLexicon.bundled())
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("yt", source: rig.en)
        rig.settle(expected: .noProposal)
        rig.deliver(" ", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "не ")
        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.text, "yt ")

        rig.deliver("ghbd", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "yt прив")
        XCTAssertEqual(rig.sourceID, rig.ru)
    }

    @MainActor
    func testConfirmedAutomaticUndoAllowsFreshWordAfterContextReset() throws {
        let rig = try AutoRig()
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")
        XCTAssertEqual(try rig.undoByDoubleShift().outcome, .confirmed(resultID: rig.en))
        XCTAssertEqual(rig.field.queuedText, 2)

        rig.field.text = ""
        rig.field.caret = 0
        rig.sourceID = rig.en
        rig.monitor.resetPredictionContext()
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")
        XCTAssertEqual(rig.field.queuedText, 3)

        rig.field.text = ""
        rig.field.caret = 0
        rig.sourceID = rig.en
        rig.monitor.resetPredictionContext()
        rig.deliver("f", source: rig.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.field.text, "а")
        XCTAssertEqual(rig.field.queuedText, 4)
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
        XCTAssertEqual(rig.monitor.predictionSessionID, beforeSession + 1,
            "Only the confirmed undo starts a fresh prediction session")
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
    func testStaleNonemptyWordHistoryUsesActualAnchoredLastWordBeforeAnyEdit() throws {
        let field = Field(pid: 5193, text: "ghbd")
        let rig = try Rig(fields: [field])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        let request = try rig.request(rig.enToRu)
        XCTAssertFalse(request.wordKeys.isEmpty)
        XCTAssertEqual(rig.run(request, direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(rig.sourceRequests, 1)

        rig.monitor.markConverted()
        rig.sourceID = rig.ruToEn.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.ruToEn), direction: rig.ruToEn).outcome,
            .confirmed(resultID: rig.ruToEn.targetLayoutID))
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.queuedText, 2)

        rig.monitor.markConverted()
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.queuedText, 3)

        rig.monitor.markConverted()
        rig.sourceID = rig.ruToEn.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.ruToEn), direction: rig.ruToEn).outcome,
            .confirmed(resultID: rig.ruToEn.targetLayoutID))
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.queuedText, 4)

        field.type(" ")
        rig.monitor.handleKeyDown(keyCode: KC.space, flags: [],
            renderedSourceLayoutID: rig.enToRu.sourceLayoutID)
        field.type("ghbd")
        try rig.type("ghbd", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "ghbd прив")
        XCTAssertEqual(field.queuedText, 5)
    }

    @MainActor
    func testStaleWordHistoryCannotWriteWithoutAnchoredWholeField() throws {
        let field = Field(pid: 5194, text: "ghbd")
        let rig = try Rig(fields: [field])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        rig.wholeObservationAvailable = false
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(rig.sourceRequests, 0)
    }

    @MainActor
    func testStaleWordFallbackRefusesMissingFirstCaretAndChangedCaret() throws {
        let field = Field(pid: 5195, text: "ghbd")
        let rig = try Rig(fields: [field])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        let captured = field.focus()
        let noCaret = CombinedShiftFocus(processID: captured.processID, element: captured.element,
            initialSelection: nil, fieldBoundary: captured.fieldBoundary)
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu, firstFocus: noCaret),
            direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.queuedText, 0)

        let request = try rig.request(rig.enToRu)
        field.caret = 3
        XCTAssertEqual(rig.run(request, direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(rig.sourceRequests, 0)
    }

    @MainActor
    func testStaleWordFallbackRefusesWrongSourceSecureReadOnlyAndUnavailableValue() throws {
        for gate in 0..<4 {
            let field = Field(pid: Int32(5200 + gate), text: "ghbd")
            let rig = try Rig(fields: [field])
            try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
            rig.sourceID = rig.enToRu.targetLayoutID
            let request = try rig.request(rig.enToRu)
            switch gate {
            case 0: rig.sourceID = rig.enToRu.sourceLayoutID
            case 1: field.secure = true
            case 2: field.readOnly = true
            default: rig.wholeObservationAvailable = false
            }
            XCTAssertEqual(rig.run(request, direction: rig.enToRu).outcome, .stopped)
            XCTAssertEqual(field.text, "ghbd")
            XCTAssertEqual(field.queuedText, 0)
            XCTAssertEqual(rig.sourceRequests, 0)
        }
    }

    @MainActor
    func testStaleWordFallbackNeverRetriesAfterUnknownMutation() throws {
        let field = Field(pid: 5205, text: "ghbd")
        field.dropInsertion = true
        let rig = try Rig(fields: [field])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: field.focus()))
        rig.converter.clearState()
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testStaleWordFallbackRefusesChangedRevisionAndProcess() throws {
        let first = Field(pid: 5206, text: "ghbd")
        let other = Field(pid: 5207, text: "ghbd")
        let rig = try Rig(fields: [first, other])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        let staleRevision = try rig.request(rig.enToRu)
        rig.monitor.handleKeyDown(keyCode: KC.space, flags: [],
            renderedSourceLayoutID: rig.enToRu.sourceLayoutID)
        XCTAssertEqual(rig.run(staleRevision, direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(first.queuedText, 0)

        let wrongProcess = try rig.request(rig.enToRu)
        rig.frontField = other
        XCTAssertEqual(rig.run(wrongProcess, direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(first.text, "ghbd")
        XCTAssertEqual(other.text, "ghbd")
        XCTAssertEqual(first.queuedText + other.queuedText, 0)
        XCTAssertEqual(rig.sourceRequests, 0)
    }

    @MainActor
    func testValidBufferDoesNotSpendLeaseOnExtraAXSuffixProbe() throws {
        let field = Field(pid: 5208, text: "ghbdtn")
        field.substringReadDelay = 0.060
        let rig = try Rig(fields: [field])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome,
            .confirmed(resultID: rig.enToRu.targetLayoutID))
        XCTAssertEqual(field.text, "привет")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(field.substringCount, 0)
    }

    @MainActor
    func testSameLengthStaleBufferSuffixStillRefusesWithoutWriting() throws {
        let field = Field(pid: 5209, text: "ghbdxx")
        let rig = try Rig(fields: [field])
        try rig.type("ghbdtn", source: rig.enToRu.sourceLayoutID)
        rig.sourceID = rig.enToRu.targetLayoutID
        XCTAssertEqual(rig.run(try rig.request(rig.enToRu), direction: rig.enToRu).outcome, .stopped)
        XCTAssertEqual(field.text, "ghbdxx")
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertEqual(rig.sourceRequests, 0)
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
