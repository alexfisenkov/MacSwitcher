import ApplicationServices
import XCTest
@testable import RuSwitcher

final class AnchorCaptureRecoveryTests: XCTestCase {
    typealias Field = ProductionCombinedShiftEditingTests.Field

    @MainActor
    private final class Rig {
        enum FirstCapture { case unavailable, noncollapsed }

        let monitor = KeyboardMonitor()
        let probe = PredictionEvaluationProbe()
        let fields: [Field]
        let englishID: String
        let russianID: String
        let firstCapture: FirstCapture
        var currentField: Field
        var sourceID: String
        var captureAttempts = 0
        var beginLeaseAttempts = 0
        var sourceSelections: [String] = []
        private var lease: InputEventFence.Lease?
        private var leaseGeneration: UInt64 = 0
        var leaseIsFree: Bool { lease == nil }

        lazy var converter = ProductionCombinedShiftEditingTests.converter(for: fields,
            automaticRoute: { _, _, _ in .nativeVerified })

        lazy var platform = PredictionCoordinatorPlatform(
            frontmost: { [unowned self] in ("com.apple.TextEdit", currentField.pid) },
            currentLayoutID: { [unowned self] in sourceID },
            route: { _, _, _ in .nativeVerified }, deniedApp: { _ in false },
            autoSwitchEnabled: { true }, autoConvertEnabled: { true },
            remoteDeferred: { false }, secureInputActive: { false },
            captureFocus: { [unowned self] pid in
                captureAttempts += 1
                guard pid == currentField.pid else { return nil }
                if captureAttempts == 1 {
                    switch firstCapture {
                    case .unavailable: return nil
                    case .noncollapsed:
                        let current = currentField.focus()
                        return CombinedShiftFocus(processID: pid, element: current.element,
                            initialSelection: CFRange(location: currentField.caret, length: 1),
                            fieldBoundary: current.fieldBoundary)
                    }
                }
                return currentField.focus()
            },
            focusIsCurrent: { [unowned self] focus in
                focus.processID == currentField.pid && CFEqual(focus.element, currentField.element)
            },
            beginLease: { [unowned self] pid in
                beginLeaseAttempts += 1
                guard lease == nil else { return nil }
                leaseGeneration &+= 1
                let next = InputEventFence.Lease(generation: leaseGeneration, processID: pid)
                lease = next
                return next
            },
            leaseIsCurrent: { [unowned self] candidate in lease == candidate },
            leaseRemaining: { [unowned self] candidate in lease == candidate ? 0.250 : nil },
            finishLease: { [unowned self] candidate, _ in
                if lease == candidate { lease = nil }
            },
            selectSource: { [unowned self] target in
                sourceSelections.append(target)
                sourceID = target
                return .confirmed
            }, sourceRequestedAt: { DispatchTime.now().uptimeNanoseconds },
            noteUnconfirmedSource: { _, _ in })

        lazy var coordinator: PredictionCoordinator = {
            let lexicon = PredictionLexicon(wordsByLanguage: [
                "ru": ["привет": 1_000_000], "en": ["hello": 900_000]
            ])
            let value = PredictionCoordinator(monitor: monitor, converter: converter,
                platform: platform, engine: PredictionEngine(lexicon: lexicon))
            value.onEvaluationFinished = { [weak probe] id, outcome in
                probe?.finished(id, outcome)
            }
            monitor.onPredictionInput = { [weak value, weak probe] snapshot in
                value?.submit(snapshot)
                probe?.submitted(value?.latestSubmittedEvaluationID)
            }
            monitor.onPredictionInvalidated = { [weak value] in value?.invalidate() }
            return value
        }()

        init(fields: [Field], englishID: String, russianID: String,
             firstCapture: FirstCapture) {
            self.fields = fields
            self.englishID = englishID
            self.russianID = russianID
            self.firstCapture = firstCapture
            currentField = fields[0]
            sourceID = englishID
        }

        func deliver(_ text: String) {
            currentField.type(text)
            monitor.recordPredictionText(text, processID: currentField.pid, sourceLayoutID: sourceID)
        }

        func manualDoubleShift(_ direction: CombinedShiftContext) throws
            -> CombinedShiftTransaction.Result {
            let contexts = [englishID: CombinedShiftContext(sourceLayoutID: englishID,
                targetLayoutID: russianID),
                russianID: CombinedShiftContext(sourceLayoutID: russianID,
                    targetLayoutID: englishID)]
            // The first solo Shift captures the field before selecting its
            // target source. No global TIS request is made by this fixture.
            _ = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .switchLayout(direction),
                frontProcessID: currentField.pid, focus: currentField.focus(),
                contextForSource: { contexts[$0] }))
            sourceID = direction.targetLayoutID
            let request = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .convert(direction),
                frontProcessID: currentField.pid, focus: nil,
                contextForSource: { contexts[$0] }))
            let execution = CombinedShiftExecutionContext(focus: try XCTUnwrap(request.focus),
                inputRevision: request.inputRevision,
                currentInputRevision: { [unowned self] in monitor.inputRevision })
            let manualPlatform = CombinedShiftTransaction.Platform(
                currentSourceID: { [unowned self] in sourceID },
                frontProcessID: { [unowned self] in currentField.pid },
                secureInputActive: { false },
                beginLease: platform.beginLease,
                leaseIsCurrent: platform.leaseIsCurrent,
                leaseRemaining: platform.leaseRemaining,
                finishLease: platform.finishLease,
                pendingSourceTargetID: { nil },
                selectSource: platform.selectSource,
                noteUnconfirmedSource: platform.noteUnconfirmedSource,
                observeWholeField: { [unowned self] focus in
                    guard focus.processID == currentField.pid,
                          CFEqual(focus.element, currentField.element) else { return nil }
                    return currentField.observation
                }, applicationFamily: { .textEdit })
            return CombinedShiftTransaction.run(request: request, context: direction,
                execution: execution, converter: converter, monitor: monitor,
                platform: manualPlatform, convertWholeLine: false,
                contextForSource: { contexts[$0] })
        }

        func typeManualKeys(_ text: String) throws {
            for character in text {
                currentField.type(String(character))
                let code = character == " " ? KC.space : try XCTUnwrap(
                    KeyMapping.keycodeToEN.first(where: { $0.value == character })?.key)
                monitor.handleKeyDown(keyCode: code, flags: [], renderedSourceLayoutID: sourceID)
            }
        }
    }

    @MainActor
    private func layoutIDs() throws -> (en: String, ru: String) {
        let layouts = LayoutSwitcher.installedLayouts()
        let en = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let ru = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        return (LayoutSwitcher.sourceID(en), LayoutSwitcher.sourceID(ru))
    }

    @MainActor
    func testFailedFirstFocusCaptureRearmsOnlyAfterWordBoundary() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 6201, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru,
            firstCapture: .unavailable)
        _ = rig.coordinator

        rig.deliver("g")
        let failedSession = rig.monitor.predictionSessionID
        rig.deliver("hbd")
        rig.probe.awaitLatest(expected: .refused)
        XCTAssertEqual(rig.captureAttempts, 1, "No late capture inside the failed word")
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.queuedText, 0)

        rig.deliver(" ")
        rig.probe.awaitLatest(expected: .notScheduled)
        XCTAssertNotEqual(rig.monitor.predictionSessionID, failedSession)
        XCTAssertEqual(rig.captureAttempts, 1, "The boundary itself must not be captured")

        rig.deliver("ghbd")
        rig.probe.awaitLatest(expected: .applied)
        XCTAssertEqual(rig.captureAttempts, 2)
        XCTAssertEqual(field.text, "ghbd прив")
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testNoncollapsedFirstCaptureCannotAdoptOtherFieldMidword() throws {
        let pair = try layoutIDs()
        let first = Field(pid: 6202, text: "")
        let second = Field(pid: 6202, text: "", element: AXUIElementCreateSystemWide())
        let rig = Rig(fields: [first, second], englishID: pair.en, russianID: pair.ru,
            firstCapture: .noncollapsed)
        _ = rig.coordinator

        rig.deliver("g")
        rig.currentField = second
        rig.deliver("hbd")
        rig.probe.awaitLatest(expected: .refused)
        XCTAssertEqual(rig.captureAttempts, 1, "No late capture in another field")
        XCTAssertEqual(second.queuedText, 0)

        rig.deliver(" ")
        rig.probe.awaitLatest(expected: .notScheduled)
        XCTAssertEqual(rig.captureAttempts, 1)
        rig.deliver("ghbd")
        rig.probe.awaitLatest(expected: .applied)
        XCTAssertEqual(rig.captureAttempts, 2)
        XCTAssertEqual(second.text, "hbd прив")
        XCTAssertEqual(first.text, "g")
    }

    @MainActor
    func testFailedAutomaticAnchorDoesNotPoisonRepeatedManualTransactions() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 6203, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru,
            firstCapture: .unavailable)
        _ = rig.coordinator
        let enToRu = CombinedShiftContext(sourceLayoutID: pair.en, targetLayoutID: pair.ru)
        let ruToEn = enToRu.reversed

        rig.deliver("ghbdtn")
        rig.probe.awaitLatest(expected: .refused)
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.queuedText, 0, "Failed automatic capture must not queue Unicode")
        XCTAssertEqual(rig.beginLeaseAttempts, 0)
        XCTAssertTrue(rig.leaseIsFree)

        let first = try rig.manualDoubleShift(enToRu)
        XCTAssertEqual(first.outcome, .confirmed(resultID: pair.ru))
        XCTAssertEqual(field.text, "привет")
        XCTAssertEqual(rig.sourceID, pair.ru)
        XCTAssertTrue(rig.leaseIsFree)

        let undo = try rig.manualDoubleShift(ruToEn)
        XCTAssertEqual(undo.outcome, .confirmed(resultID: pair.en))
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(rig.sourceID, pair.en)
        XCTAssertTrue(rig.leaseIsFree)

        let redo = try rig.manualDoubleShift(enToRu)
        XCTAssertEqual(redo.outcome, .confirmed(resultID: pair.ru))
        XCTAssertEqual(field.text, "привет")
        XCTAssertEqual(rig.sourceID, pair.ru)
        XCTAssertTrue(rig.leaseIsFree)

        rig.sourceID = pair.en // explicit user source choice before the next word
        try rig.typeManualKeys(" ghbdtn")
        let nextWord = try rig.manualDoubleShift(enToRu)
        XCTAssertEqual(nextWord.outcome, .confirmed(resultID: pair.ru))
        XCTAssertEqual(field.text, "привет привет")
        XCTAssertEqual(rig.sourceID, pair.ru)
        XCTAssertEqual(rig.sourceSelections.count, 4)
        XCTAssertEqual(rig.beginLeaseAttempts, 4)
        XCTAssertTrue(rig.leaseIsFree)
    }
}
