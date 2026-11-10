import ApplicationServices
import XCTest
@testable import RuSwitcher

/// Waits for the submitted coordinator task, including a no-proposal or cancelled
/// task. It observes numeric IDs only and never treats unchanged field text as idle.
@MainActor
final class PredictionEvaluationProbe {
    private(set) var latestSubmitted: PredictionEvaluationID?
    private var lastSettled: PredictionEvaluationID?
    private var outcomes: [PredictionEvaluationID: PredictionEvaluationOutcome] = [:]
    private var completionCounts: [PredictionEvaluationID: Int] = [:]
    private var retryCounts: [PredictionEvaluationID: Int] = [:]
    private var recent: [(PredictionEvaluationID, PredictionEvaluationOutcome)] = []
    var onRetryScheduled: ((PredictionEvaluationID) -> Void)?

    var lastOutcome: PredictionEvaluationOutcome? {
        lastSettled.flatMap { outcomes[$0] }
    }

    func outcome(for evaluationID: PredictionEvaluationID) -> PredictionEvaluationOutcome? {
        outcomes[evaluationID]
    }

    func completionCount(for evaluationID: PredictionEvaluationID) -> Int {
        completionCounts[evaluationID] ?? 0
    }

    func retryCount(for evaluationID: PredictionEvaluationID) -> Int {
        retryCounts[evaluationID] ?? 0
    }

    func submitted(_ evaluationID: PredictionEvaluationID?) {
        latestSubmitted = evaluationID
    }

    func finished(_ evaluationID: PredictionEvaluationID, _ outcome: PredictionEvaluationOutcome) {
        let count = (completionCounts[evaluationID] ?? 0) + 1
        completionCounts[evaluationID] = count
        XCTAssertEqual(count, 1, "Duplicate evaluation completion for sequence \(evaluationID.sequence)")
        outcomes[evaluationID] = outcome
        recent.append((evaluationID, outcome))
        if recent.count > 12 { recent.removeFirst() }
    }

    func retryScheduled(_ evaluationID: PredictionEvaluationID) {
        retryCounts[evaluationID, default: 0] += 1
        onRetryScheduled?(evaluationID)
    }

    func awaitLatest(expected: PredictionEvaluationOutcome? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date(timeIntervalSinceNow: 2.0)
        while let evaluationID = latestSubmitted, evaluationID != lastSettled {
            while outcomes[evaluationID] == nil && Date() < deadline {
                RunLoop.main.run(until: min(Date(timeIntervalSinceNow: 0.010), deadline))
            }
            let stages = recent.map { "\($0.0.sequence):\($0.0.sessionID):\($0.0.inputRevision):\($0.1.rawValue)" }
                .joined(separator: ",")
            guard let outcome = outcomes[evaluationID] else {
                XCTFail("Evaluation did not finish for session \(evaluationID.sessionID), revision \(evaluationID.inputRevision); recent=\(stages)",
                    file: file, line: line)
                return
            }
            lastSettled = evaluationID
            if let expected, outcome != expected {
                XCTFail("Expected evaluation \(expected.rawValue), got \(outcome.rawValue); recent=\(stages)",
                    file: file, line: line)
            }
        }
    }
}

final class ProductionPredictionCoordinatorTests: XCTestCase {
    typealias Field = ProductionCombinedShiftEditingTests.Field

    @MainActor
    private final class Rig {
        let monitor = KeyboardMonitor()
        let probe = PredictionEvaluationProbe()
        let fields: [Field]
        let englishID: String
        let russianID: String
        let engine: PredictionEngine
        var currentField: Field
        var sourceID: String
        var remainingBudget: TimeInterval = 0.250
        var activeLease: InputEventFence.Lease?
        var beginLeaseAttempts = 0
        var generation: UInt64 = 0
        var sourceSelections: [String] = []
        var sourceOutcome: LayoutSelectionCommit.Outcome = .confirmed
        var sourceFailures: [(target: String, outcome: LayoutSelectionCommit.Outcome?, leaseReleased: Bool)] = []
        var applied: [String] = []
        var notices: [ConfirmedCorrectionNotice] = []
        var unknownNotices = 0
        var onApplication: (() -> Void)?
        var captureAvailable = true
        var captureFocusCount = 0
        var searchOverlayActive = false

        lazy var converter = ProductionCombinedShiftEditingTests.converter(for: fields,
            automaticRoute: { _, _, _ in .nativeVerified })

        lazy var platform = PredictionCoordinatorPlatform(
            frontmost: { [unowned self] in ("com.apple.TextEdit", currentField.pid) },
            currentLayoutID: { [unowned self] in sourceID },
            route: { _, _, _ in .nativeVerified }, deniedApp: { _ in false },
            autoSwitchEnabled: { true }, autoConvertEnabled: { true }, remoteDeferred: { false },
            secureInputActive: { [unowned self] in currentField.secure },
            captureFocus: { [unowned self] pid in
                captureFocusCount += 1
                return captureAvailable && pid == currentField.pid ? currentField.focus() : nil
            },
            focusIsCurrent: { [unowned self] focus in
                currentField.pid == focus.processID && currentField.valid
                    && CFEqual(currentField.element, focus.element)
            },
            beginLease: { [unowned self] pid in
                beginLeaseAttempts += 1
                guard activeLease == nil, !monitor.hasPendingInputSourceTransition else { return nil }
                generation &+= 1
                let lease = InputEventFence.Lease(generation: generation, processID: pid)
                activeLease = lease
                return lease
            },
            leaseIsCurrent: { [unowned self] lease in activeLease == lease && remainingBudget > 0 },
            leaseRemaining: { [unowned self] lease in activeLease == lease ? remainingBudget : nil },
            finishLease: { [unowned self] lease, _ in
                if activeLease == lease { activeLease = nil }
            },
            selectSource: { [unowned self] target in
                sourceSelections.append(target)
                if sourceOutcome == .confirmed { sourceID = target }
                return sourceOutcome
            }, sourceRequestedAt: { DispatchTime.now().uptimeNanoseconds },
            noteUnconfirmedSource: { [unowned self] target, at in
                monitor.noteUnconfirmedInputSource(target, requestedAt: at)
            }, searchOverlayActive: { [unowned self] in searchOverlayActive })

        lazy var coordinator: PredictionCoordinator = {
            let value = PredictionCoordinator(monitor: monitor, converter: converter, platform: platform, engine: engine)
            value.onApplied = { [unowned self] word in
                applied.append(word)
                onApplication?()
            }
            value.onUnconfirmedEdit = { [unowned self] in unknownNotices += 1 }
            value.onCorrection = { [unowned self] in notices.append($0) }
            value.onSourceFailure = { [unowned self] target, outcome in
                sourceFailures.append((target, outcome, activeLease == nil))
            }
            value.onEvaluationFinished = { [weak probe] evaluationID, outcome in probe?.finished(evaluationID, outcome) }
            value.onRenderRetryScheduled = { [weak probe] evaluationID in probe?.retryScheduled(evaluationID) }
            monitor.onPredictionInput = { [weak value, weak probe] snapshot in
                value?.submit(snapshot)
                probe?.submitted(value?.latestSubmittedEvaluationID)
            }
            monitor.onPredictionInvalidated = { [weak value] in value?.invalidate() }
            return value
        }()

        init(fields: [Field], englishID: String, russianID: String,
             lexicon suppliedLexicon: PredictionLexicon? = nil) {
            self.fields = fields
            self.englishID = englishID
            self.russianID = russianID
            currentField = fields[0]
            sourceID = englishID
            let lexicon = PredictionLexicon(wordsByLanguage: [
                "ru": ["привет": 1_000_000, "думаю": 800_000, "что-то": 600_000,
                       "такое": 500_000, "а": 8_000_000],
                "en": ["hello": 900_000, "press": 500_000, "f": 20_000]
            ])
            engine = PredictionEngine(lexicon: suppliedLexicon ?? lexicon)
        }

        func deliver(_ text: String, to field: Field? = nil, source: String? = nil) {
            let destination = field ?? currentField
            destination.type(text)
            monitor.recordPredictionText(text, processID: destination.pid, sourceLayoutID: source ?? sourceID)
        }

        func settle(expected: PredictionEvaluationOutcome? = nil) {
            probe.awaitLatest(expected: expected)
        }

        func deliverPhysicalEnglishKeys(_ raw: String) {
            for character in raw {
                if character == " " { deliver(" "); continue }
                guard let key = KeyMapping.keycodeToEN.first(where: { $0.value == character })?.key else {
                    preconditionFailure("Missing synthetic key mapping")
                }
                let rendered = sourceID == englishID ? character : (KeyMapping.keycodeToRU[key] ?? character)
                deliver(String(rendered), source: sourceID)
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
    func testVisibleSearchOverlayDoesNotAnchorOrEditUnderlay() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2099, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        rig.searchOverlayActive = true
        _ = rig.coordinator
        rig.deliver("ghbd")
        rig.settle(expected: .stale)
        XCTAssertEqual(rig.captureFocusCount, 0)
        XCTAssertEqual(rig.beginLeaseAttempts, 0)
        XCTAssertEqual(field.text, "ghbd")
    }

    @MainActor
    func testAutomaticCorrectionResumesAfterManualEnglishWord() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2090, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.sourceID = pair.ru
        rig.deliver("Ьфс", source: pair.ru)
        rig.settle(expected: .noProposal)
        let focus = field.focus()
        let before = field.observation
        field.text = "MacSwitcher"
        field.caret = 11
        field.selection = 0
        let confirmed = TextConverter.ConfirmedNativeField(focus: focus, original: "Ьфс",
            replacement: "MacSwitcher", before: before, after: field.observation)
        rig.monitor.adoptConfirmedManualField(confirmed, resultLayoutID: pair.en)
        rig.sourceID = pair.en
        rig.deliver(" ")
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "MacSwitcher прив")
    }

    @MainActor
    func testRussianPriorityAfterConfirmedManualBrandAppliesShortWordAndSelectsRussian() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2092, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru,
            lexicon: try PredictionLexicon.bundled())
        rig.coordinator.russianPriorityProvider = { true }
        rig.sourceID = pair.ru
        rig.deliver("Ьфс", source: pair.ru)
        rig.settle(expected: .noProposal)
        let focus = field.focus()
        let before = field.observation
        field.text = "MacSwitcher"
        field.caret = 11
        field.selection = 0
        let confirmed = TextConverter.ConfirmedNativeField(focus: focus, original: "Ьфс",
            replacement: "MacSwitcher", before: before, after: field.observation)
        rig.monitor.adoptConfirmedManualField(confirmed, resultLayoutID: pair.en)
        rig.sourceID = pair.en
        rig.deliver(" ")
        rig.deliver("f")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "MacSwitcher а")
        XCTAssertEqual(rig.sourceID, pair.ru)
        XCTAssertEqual(rig.applied.last, "f")
    }

    @MainActor
    func testConfirmedUndoHoldIsBoundToFieldWhenSamePIDAndSourceMoves() throws {
        let pair = try layoutIDs()
        let a = Field(pid: 2093, text: "")
        let b = Field(pid: 2093, text: "", element: AXUIElementCreateSystemWide())
        XCTAssertFalse(CFEqual(a.element, b.element))
        let rig = Rig(fields: [a, b], englishID: pair.en, russianID: pair.ru)
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f")
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Undo must be confirmed"); return }
        }
        XCTAssertEqual(a.text, "f")
        XCTAssertEqual(rig.sourceID, pair.en)

        rig.currentField = b // Same process and layout; no monitor reset is injected.
        rig.deliver("f")
        rig.settle(expected: .applied)
        XCTAssertEqual(a.text, "f")
        XCTAssertEqual(b.text, "а")
        XCTAssertEqual(rig.sourceID, pair.ru)
    }

    @MainActor
    func testConfirmedUndoHoldKeepsSameFieldContinuationAndUnavailableFocusSafe() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2094, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f")
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Undo must be confirmed"); return }
        }
        let settled = rig.probe.latestSubmitted
        rig.captureAvailable = false
        rig.deliver("o")
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        XCTAssertEqual(field.text, "fo")
        XCTAssertEqual(rig.sourceID, pair.en)
        rig.captureAvailable = true
        rig.deliver("o")
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        XCTAssertEqual(field.text, "foo")
        rig.deliver(" ")
        XCTAssertEqual(field.text, "foo ")
        rig.deliver("f")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "foo а")
    }

    @MainActor
    func testConfirmedUndoHoldReleasesFocusAfterWordBoundary() throws {
        let pair = try layoutIDs()
        let a = Field(pid: 2095, text: "")
        let b = Field(pid: 2095, text: "", element: AXUIElementCreateSystemWide())
        let rig = Rig(fields: [a, b], englishID: pair.en, russianID: pair.ru)
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f")
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Undo must be confirmed"); return }
        }
        rig.deliver(" ")
        let capturesAfterBoundary = rig.captureFocusCount
        rig.currentField = b
        rig.deliver("f")
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.captureFocusCount, capturesAfterBoundary + 1,
            "Ordinary next-word capture must not probe the old undo field")
        XCTAssertEqual(a.text, "f ")
        XCTAssertEqual(b.text, "а")
    }

    @MainActor
    func testConfirmedUndoHoldSurvivesObservedLayoutFlipUntilSeparator() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2096, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f")
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Undo must be confirmed"); return }
        }
        let settled = rig.probe.latestSubmitted

        rig.sourceID = pair.ru
        rig.monitor.resetLineBuffer(sourceLayoutID: pair.ru)
        rig.deliver("о", source: pair.ru)
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        XCTAssertEqual(field.text, "fо")
        rig.deliver(" ", source: pair.ru)
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        rig.sourceID = pair.en
        rig.monitor.resetLineBuffer(sourceLayoutID: pair.en)
        rig.deliver("ghbd", source: pair.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "fо прив")
        XCTAssertEqual(rig.sourceID, pair.ru)
    }

    @MainActor
    func testConfirmedUndoHoldSurvivesNewSourceGlyphBeforeTISNotification() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2097, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f")
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Undo must be confirmed"); return }
        }
        let settled = rig.probe.latestSubmitted

        rig.sourceID = pair.ru
        rig.deliver("о", source: pair.ru) // Actual rendered source arrives before its TIS notification.
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        XCTAssertEqual(field.text, "fо")
        rig.monitor.resetLineBuffer(sourceLayoutID: pair.ru)
        rig.deliver(" ", source: pair.ru)
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        rig.sourceID = pair.en
        rig.monitor.resetLineBuffer(sourceLayoutID: pair.en)
        rig.deliver("ghbd", source: pair.en)
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "fо прив")
    }

    @MainActor
    func testUnavailableFocusOnUndoWordSeparatorLetsNextWordStartFresh() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2098, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f")
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Undo must be confirmed"); return }
        }
        let settled = rig.probe.latestSubmitted
        rig.captureAvailable = false
        rig.deliver(" ") // Physical whitespace reaches the field while AX is unavailable.
        XCTAssertEqual(field.text, "f ")
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        rig.captureAvailable = true
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "f прив")
        XCTAssertEqual(rig.sourceID, pair.ru)
    }

    @MainActor
    func testUnavailableFocusOnMixedPacketDoesNotScorePartialNextWord() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2099, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f")
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Undo must be confirmed"); return }
        }
        let settled = rig.probe.latestSubmitted
        rig.captureAvailable = false
        rig.deliver(" ghbd")
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        rig.captureAvailable = true
        rig.deliver("tn")
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        XCTAssertEqual(field.text, "f ghbdtn")
        XCTAssertEqual(rig.sourceID, pair.en)
    }

    @MainActor
    func testUnavailableFocusOnPacketEndingInSpaceClosesUndoHold() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2100, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f")
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Undo must be confirmed"); return }
        }
        let settled = rig.probe.latestSubmitted
        rig.captureAvailable = false
        rig.deliver("oo ") // Unknown AX identity, but packet ends at a word boundary.
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        XCTAssertEqual(field.text, "foo ")
        rig.captureAvailable = true
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "foo прив")
        XCTAssertEqual(rig.sourceID, pair.ru)
    }

    @MainActor
    func testHeldContinuationUsesIdentityProbeWithoutFullCaptureOrLease() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2101, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        var identityReads = 0
        rig.platform.focusedIdentity = { [unowned rig] pid in
            identityReads += 1
            return identityReads == 1 && pid == rig.currentField.pid ? rig.currentField.element : nil
        }
        rig.coordinator.russianPriorityProvider = { true }
        rig.deliver("f")
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Undo must be confirmed"); return }
        }
        let fullCaptures = rig.captureFocusCount
        let leases = rig.beginLeaseAttempts
        let settled = rig.probe.latestSubmitted
        rig.deliver("o") // Same field: only the identity seam is used.
        XCTAssertEqual(identityReads, 1)
        XCTAssertEqual(rig.captureFocusCount, fullCaptures)
        rig.deliver("o") // Simulated unavailable/slow AX result.
        XCTAssertEqual(identityReads, 2)
        XCTAssertEqual(rig.captureFocusCount, fullCaptures)
        XCTAssertEqual(rig.beginLeaseAttempts, leases)
        XCTAssertEqual(rig.probe.latestSubmitted, settled)
        XCTAssertEqual(field.text, "foo")
        XCTAssertEqual(rig.sourceID, pair.en)
    }

    @MainActor
    func testLostFocusAnchorRecoversAfterWordBoundary() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2091, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.deliver("ghbd")
        field.valid = false
        rig.settle(expected: .refused)
        XCTAssertEqual(field.text, "ghbd")

        field.valid = true
        rig.deliver(" ")
        rig.settle(expected: .notScheduled)
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "ghbd прив")
    }

    @MainActor
    func testAdaptiveWordAppliesWithStaleReportedLayoutInBothDirections() throws {
        let pair = try layoutIDs()
        let wordPair = AdaptiveWordPair(ru: "фис", en: "abc")
        let forward = AdaptiveRule(pair: wordPair, preferred: "ru", confirmations: 2,
            confirmedAt: Date(), lastOccurrenceID: UUID())
        let first = Field(pid: 2071, text: "")
        let rig = Rig(fields: [first], englishID: pair.en, russianID: pair.ru)
        rig.coordinator.adaptiveRulesProvider = { [forward] in [forward] }
        rig.sourceID = pair.ru
        rig.deliver("abc ", source: pair.ru)
        rig.settle(expected: .applied)
        XCTAssertEqual(first.text, "фис ")
        XCTAssertEqual(rig.sourceID, pair.ru)

        let reverse = AdaptiveRule(pair: wordPair, preferred: "en", confirmations: 2,
            confirmedAt: Date(), lastOccurrenceID: UUID())
        let second = Field(pid: 2072, text: "")
        let reverseRig = Rig(fields: [second], englishID: pair.en, russianID: pair.ru)
        reverseRig.coordinator.adaptiveRulesProvider = { [reverse] in [reverse] }
        reverseRig.deliver("фис ", source: pair.en)
        reverseRig.settle(expected: .applied)
        XCTAssertEqual(second.text, "abc ")
        XCTAssertEqual(reverseRig.sourceID, pair.en)
    }

    @MainActor
    func testEvaluationCompletionDistinguishesNoProposalApplicationAndCancellationAfterUndo() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2040, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.settle() // No submission must not wait for a completion that cannot exist.

        rig.deliver("hello")
        rig.settle(expected: .noProposal)
        XCTAssertEqual(field.queuedText, 0)

        field.text = ""; field.caret = 0; field.selection = 0
        rig.monitor.resetPredictionContext()
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        let notice = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: notice.id) { result in
            guard case .confirmed = result else { XCTFail("Expected confirmed undo"); return }
        }

        field.text = ""; field.caret = 0; field.selection = 0
        rig.monitor.resetPredictionContext()
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "прив")

        field.text = ""; field.caret = 0; field.selection = 0
        rig.monitor.resetPredictionContext()
        rig.deliver("ghbd")
        XCTAssertNotNil(rig.probe.latestSubmitted)
        rig.coordinator.invalidate()
        rig.settle(expected: .cancelledBeforeEvaluation)
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.queuedText, 3) // Two forward edits and one undo, no cancelled write.
    }

    @MainActor
    func testIdenticalSnapshotCountersHaveDistinctSubmissionTokens() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2041, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.deliver("g")
        let first = try XCTUnwrap(rig.probe.latestSubmitted)
        rig.deliver("h")
        let second = try XCTUnwrap(rig.probe.latestSubmitted)
        rig.deliver("bd")
        let latest = try XCTUnwrap(rig.probe.latestSubmitted)

        XCTAssertEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(first.inputRevision, second.inputRevision)
        XCTAssertEqual(first.generation, second.generation)
        XCTAssertNotEqual(first.sequence, second.sequence)
        XCTAssertNotEqual(second.sequence, latest.sequence)
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(rig.probe.outcome(for: first), .cancelledBeforeEvaluation)
        XCTAssertEqual(rig.probe.outcome(for: second), .cancelledBeforeEvaluation)
        XCTAssertEqual(rig.probe.completionCount(for: first), 1)
        XCTAssertEqual(rig.probe.completionCount(for: second), 1)
        XCTAssertEqual(rig.probe.completionCount(for: latest), 1)
    }

    @MainActor
    func testMainQueueCongestionCannotEndWaitBeforeSubmittedEvaluation() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2042, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.deliver("ghbd")
        let evaluationID = try XCTUnwrap(rig.probe.latestSubmitted)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
            Thread.sleep(forTimeInterval: 0.200) // Test-only main queue contention before 70 ms debounce.
        }
        rig.settle(expected: .applied)
        XCTAssertEqual(rig.probe.completionCount(for: evaluationID), 1)
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testSupersededRenderRetryCompletesOnceAndCannotFinishNewSubmission() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2043, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        let coordinator = rig.coordinator
        rig.deliver("ghbd")
        let old = try XCTUnwrap(rig.probe.latestSubmitted)
        field.text = "ghbX" // Same caret, but rendered suffix is not the submitted source.
        rig.probe.onRetryScheduled = { [weak coordinator] evaluationID in
            if evaluationID == old { coordinator?.invalidate() }
        }
        rig.settle(expected: .cancelledBeforeEvaluation)
        XCTAssertEqual(rig.probe.retryCount(for: old), 1)
        XCTAssertEqual(rig.probe.completionCount(for: old), 1)
        XCTAssertEqual(field.queuedText, 0)

        rig.probe.onRetryScheduled = nil
        field.text = ""; field.caret = 0; field.selection = 0
        rig.monitor.resetPredictionContext()
        rig.deliver("ghbd")
        let current = try XCTUnwrap(rig.probe.latestSubmitted)
        XCTAssertNotEqual(old.sequence, current.sequence)
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertEqual(rig.probe.completionCount(for: current), 1)
        XCTAssertEqual(rig.probe.completionCount(for: old), 1)
    }

    @MainActor
    func testRenderRetryExhaustionKeepsOneTokenAndOneTerminalCompletion() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2044, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.deliver("ghbd")
        let evaluationID = try XCTUnwrap(rig.probe.latestSubmitted)
        field.text = "ghbX"
        rig.settle(expected: .renderRetryExhausted)
        XCTAssertEqual(rig.probe.retryCount(for: evaluationID), 3)
        XCTAssertEqual(rig.probe.completionCount(for: evaluationID), 1)
        XCTAssertEqual(field.text, "ghbX")
        XCTAssertEqual(field.queuedText, 0)
    }

    @MainActor
    func testRealSubmitEvaluateAppliesEarlyThenContinuesNextWordAndNewField() throws {
        let pair = try layoutIDs()
        let a = Field(pid: 2011, text: "")
        let b = Field(pid: 2011, text: "", element: AXUIElementCreateSystemWide())
        XCTAssertFalse(CFEqual(a.element, b.element))
        let rig = Rig(fields: [a, b], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator

        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        XCTAssertEqual(a.text, "прив")
        XCTAssertEqual(a.queuedText, 1)
        XCTAssertEqual(rig.sourceID, pair.ru)

        rig.deliver("ет")
        rig.settle()
        XCTAssertEqual(a.text, "привет")
        rig.deliver(" ")
        rig.deliver("руддщ")
        rig.settle(expected: .applied)
        XCTAssertEqual(a.text, "привет hello")
        XCTAssertEqual(a.queuedText, 2)

        rig.currentField = b
        rig.sourceID = pair.en
        rig.monitor.resetPredictionContext()
        rig.deliver("ghbdtn")
        rig.settle(expected: .applied)
        XCTAssertEqual(b.text, "привет")
        XCTAssertEqual(a.text, "привет hello")
        XCTAssertEqual(rig.applied.count, 3)
    }

    @MainActor
    func testToastUndoKeepsConfirmedOriginalUntilNextWordBoundary() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2031, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "прив")
        let notice = try XCTUnwrap(rig.notices.last)

        var adaptiveEvent: (UUID, String, String)?
        rig.coordinator.onAdaptiveAutomaticUndo = { id, original, replacement, _, _ in
            XCTAssertNil(rig.activeLease, "Learning event must follow lease release")
            adaptiveEvent = (id, original, replacement)
        }

        var undoResult: CorrectionUndoResult?
        rig.coordinator.undoCorrection(id: notice.id) { undoResult = $0 }
        guard case .confirmed? = undoResult else {
            XCTFail("Expected confirmed toast undo, got \(String(describing: undoResult))")
            return
        }
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(rig.sourceID, pair.en)
        XCTAssertEqual(adaptiveEvent?.0, notice.id)
        XCTAssertEqual(adaptiveEvent?.1, "прив")
        XCTAssertEqual(adaptiveEvent?.2, "ghbd")

        rig.deliver("tn")
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(rig.sourceID, pair.en)
    }

    @MainActor
    func testToastUndoWithConfirmedTextAndFailedSourceReportsSourceFailure() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2033, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "прив")
        let notice = try XCTUnwrap(rig.notices.last)
        rig.sourceOutcome = .refused

        var adaptiveEventCount = 0
        rig.coordinator.onAdaptiveAutomaticUndo = { _, _, _, _, _ in adaptiveEventCount += 1 }

        var result: CorrectionUndoResult?
        rig.coordinator.undoCorrection(id: notice.id) { result = $0 }
        guard case .sourceNotConfirmed(let target)? = result else {
            XCTFail("Confirmed reverse text with failed source needs a source instruction")
            return
        }
        XCTAssertEqual(target, pair.en)
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(adaptiveEventCount, 0)
        XCTAssertEqual(field.queuedText, 2)
        XCTAssertFalse(rig.converter.hasUnconfirmedAXEdit(in: field.focus()),
            "A failed source selection is not an unknown text write")
        XCTAssertTrue(CorrectionFeedbackPolicy.sourceMessage(languageCode: "ru").contains("расклад"))
    }

    @MainActor
    func testToastUndoSkipsCurrentTokenThenAllowsFreshProposal() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2032, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        let first = try XCTUnwrap(rig.notices.last)
        rig.coordinator.undoCorrection(id: first.id) { result in
            guard case .confirmed = result else { XCTFail("Expected confirmed undo"); return }
        }
        XCTAssertEqual(field.text, "ghbd")

        rig.deliver("tn")
        XCTAssertEqual(field.text, "ghbdtn")
        rig.deliver(" ")
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "ghbdtn прив")
    }

    @MainActor
    func testRealSubmitNearExpiryRefusesBeforeSelectionAndUnknownNeverReplays() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2013, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.remainingBudget = 0.010
        rig.deliver("ghbd")
        rig.settle(expected: .refused)
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.queuedSelection, 0)
        XCTAssertEqual(field.queuedText, 0)
        XCTAssertFalse(rig.converter.hasUnconfirmedAXEdit)

        rig.monitor.resetPredictionContext()
        field.text = ""
        field.caret = 0
        field.selection = 0
        rig.remainingBudget = 0.250
        field.dropInsertion = true
        rig.deliver("ghbd")
        rig.settle(expected: .textUnconfirmed)
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: field.focus()))
        XCTAssertEqual(rig.converter.unconfirmedOriginals.first?.text, "ghbd")
        XCTAssertEqual(rig.unknownNotices, 1)
        rig.deliver("!")
        rig.settle()
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testUnknownFieldSkipsLaterAutomaticLeaseButDifferentFieldCanStillEdit() throws {
        let pair = try layoutIDs()
        let unknown = Field(pid: 2020, text: "")
        let other = Field(pid: 2020, text: "", element: AXUIElementCreateSystemWide())
        let rig = Rig(fields: [unknown, other], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        unknown.dropInsertion = true

        rig.deliver("ghbd")
        rig.settle(expected: .textUnconfirmed)
        XCTAssertEqual(unknown.queuedText, 1)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: unknown.focus()))
        XCTAssertEqual(rig.beginLeaseAttempts, 1)

        // User input after the unknown delivery leaves the original quarantined.
        rig.deliver("!")
        rig.sourceID = pair.en
        rig.monitor.resetPredictionContext()
        rig.deliver("ghbd")
        rig.settle(expected: .refused)
        XCTAssertEqual(rig.beginLeaseAttempts, 1,
            "The same quarantined field must not open another input lease")
        XCTAssertEqual(unknown.queuedText, 1)

        rig.currentField = other
        rig.monitor.resetPredictionContext()
        rig.deliver("ghbd")
        rig.settle(expected: .applied)
        XCTAssertEqual(other.text, "прив")
        XCTAssertEqual(other.queuedText, 1)
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: unknown.focus()))
    }

    @MainActor
    func testUnknownAutomaticTextDoesNotSelectSourceBeforeTextAcknowledgement() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2021, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        field.dropInsertion = true
        rig.sourceOutcome = .unconfirmed

        rig.deliver("ghbd")
        rig.settle(expected: .textUnconfirmed)
        XCTAssertEqual(field.queuedText, 1, "This is an unknown post-queue result")
        XCTAssertTrue(rig.converter.hasUnconfirmedAXEdit(in: field.focus()))
        XCTAssertEqual(rig.sourceSelections, [],
            "An unconfirmed text delivery cannot justify selecting its result layout")
        XCTAssertEqual(rig.sourceID, pair.en)
        XCTAssertFalse(rig.monitor.hasPendingInputSourceTransition)
    }

    @MainActor
    func testDeferredCoordinatorRejectsFieldSwitchAndSecureInputBeforeWrite() throws {
        let pair = try layoutIDs()
        let a = Field(pid: 2014, text: "")
        let b = Field(pid: 2014, text: "", element: AXUIElementCreateSystemWide())
        XCTAssertFalse(CFEqual(a.element, b.element))
        let rig = Rig(fields: [a, b], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.deliver("ghbd")
        rig.currentField = b
        rig.settle()
        XCTAssertEqual(a.text, "ghbd")
        XCTAssertEqual(a.queuedText, 0)
        XCTAssertEqual(b.queuedText, 0)

        rig.currentField = a
        rig.monitor.resetPredictionContext()
        a.secure = true
        rig.deliver("ghbd")
        rig.settle()
        XCTAssertEqual(a.queuedText, 0)
        XCTAssertEqual(rig.applied.count, 0)
    }

    @MainActor
    func testExactOwnerExampleAsSuccessiveAutomaticWordSnapshots() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2016, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator

        rig.deliver("MacSwitcher ", source: pair.en)
        rig.settle()
        XCTAssertEqual(field.text, "MacSwitcher ")
        XCTAssertEqual(field.queuedText, 0)

        rig.deliverPhysicalEnglishKeys("levf.")
        rig.settle()
        rig.deliver(" ")
        rig.settle()
        XCTAssertEqual(field.text, "MacSwitcher думаю ")

        // After automatic source selection, the same physical keys render in
        // Russian. No extra user Shift or expected-result paste is injected.
        rig.deliverPhysicalEnglishKeys("xnj-nj")
        rig.settle()
        rig.deliver(" ")
        rig.settle()
        XCTAssertEqual(field.text, "MacSwitcher думаю что-то ")

        rig.deliverPhysicalEnglishKeys("nfrjt")
        rig.settle()
        XCTAssertEqual(field.text, "MacSwitcher думаю что-то такое")
        XCTAssertEqual(field.queuedText, 1)
    }

    @MainActor
    func testConfirmedAutomaticTextWithRefusedSourceExplainsAndPreservesUndo() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2017, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.sourceOutcome = .refused

        rig.deliver("ghbd")
        rig.settle(expected: .sourceUnconfirmed)
        XCTAssertEqual(field.text, "прив", "Text ACK is independent of source refusal")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(rig.converter.hasReconversionState)
        XCTAssertFalse(rig.monitor.keysTypedSinceConversion,
            "Confirmed text must establish undo state even if TIS selection fails")
        XCTAssertEqual(rig.sourceFailures.count, 1)
        XCTAssertEqual(rig.sourceFailures.first?.target, pair.ru)
        XCTAssertEqual(rig.sourceFailures.first?.outcome, .refused)
        XCTAssertEqual(rig.sourceFailures.first?.leaseReleased, true)
        XCTAssertNotNil(CombinedShiftFailure.sourceNotConfirmed.userMessage)
        XCTAssertEqual(field.queuedText, 1, "Source repair never resends Unicode")
    }

    @MainActor
    func testUnconfirmedAutomaticSourceBlocksUntilActualTargetObservedThenNextWordWorks() throws {
        let pair = try layoutIDs()
        let field = Field(pid: 2018, text: "")
        let rig = Rig(fields: [field], englishID: pair.en, russianID: pair.ru)
        _ = rig.coordinator
        rig.sourceOutcome = .unconfirmed

        rig.deliver("ghbd")
        rig.settle(expected: .sourceUnconfirmed)
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.queuedText, 1)
        XCTAssertTrue(rig.monitor.hasPendingInputSourceTransition)
        XCTAssertEqual(rig.sourceFailures.count, 1)
        XCTAssertEqual(rig.sourceFailures.first?.outcome, .unconfirmed)
        XCTAssertEqual(rig.sourceFailures.first?.leaseReleased, true)

        rig.monitor.recordObservedInputSource(pair.en)
        XCTAssertTrue(rig.monitor.hasPendingInputSourceTransition,
            "Observing the old source cannot clear a pending requested target")
        rig.sourceID = pair.ru // synthetic fresh TIS read-back after explicit user selection
        rig.monitor.recordObservedInputSource(rig.sourceID)
        XCTAssertFalse(rig.monitor.hasPendingInputSourceTransition)

        rig.sourceOutcome = .confirmed
        rig.deliver("ет ")
        rig.settle()
        rig.deliver("руддщ")
        rig.settle(expected: .applied)
        XCTAssertEqual(field.text, "привет hello")
        XCTAssertEqual(field.queuedText, 2)
    }
}
