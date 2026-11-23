import AppKit

/// Numeric identity of one submitted prediction; never carries typed text.
struct PredictionEvaluationID: Hashable, Sendable {
    let sequence: UInt64
    let sessionID: UInt64
    let inputRevision: UInt64
    let generation: UInt64

    init(_ snapshot: PredictionSnapshot, sequence: UInt64) {
        self.sequence = sequence
        sessionID = snapshot.sessionID
        inputRevision = snapshot.inputRevision
        generation = snapshot.generation
    }
}

/// Closed result vocabulary for causal test observation; no field content.
enum PredictionEvaluationOutcome: String, Equatable, Sendable {
    case notScheduled, cancelledBeforeEvaluation, stale, engineUnavailable
    case mappingUnavailable, noProposal, rejected, suppressed, refused, renderRetryExhausted
    case textUnconfirmed, sourceUnconfirmed, applied
    /// The engine only offered a word; nothing was written.
    case hinted
}

/// Dictionary loading/scoring runs outside the HID callback. The first event of
/// each session captures its original AX field once (existing 50 ms timeouts);
/// later AX reads are limited to a concrete, still-current edit. A deferred first
/// capture could attach a burst's caret to the wrong event or adopt another field.
@MainActor
final class PredictionCoordinator {
    private let monitor: KeyboardMonitor
    private let converter: TextConverter
    private let platform: PredictionCoordinatorPlatform
    private let engineTask: Task<PredictionEngine?, Never>
    private var nextEvaluationSequence: UInt64 = 0
    private(set) var latestSubmittedEvaluationID: PredictionEvaluationID?
    private var debounce: DispatchWorkItem?
    private var pendingDebounceID: PredictionEvaluationID?
    private var evaluation: Task<Void, Never>?
    private var anchorSessionID: UInt64?
    private var anchorFocus: CombinedShiftFocus?
    private var pendingCaretAnchor: PredictionPendingCaretAnchor?
    private var anchorProofDeferred = false
    private let correctionReceipts: ConfirmedCorrectionReceipts
    private let receiptNow: () -> UInt64
    private let diagnosticsEnabled: () -> Bool
    private let loopGuard: AutoCorrectionLoopGuard
    private let loopClock: () -> TimeInterval
    private let recordAutomaticUncertain: (CombinedShiftApplicationFamily) -> Void
    private var confirmedAdaptiveUndo: (id: UUID, original: String, replacement: String,
                                        focus: CombinedShiftFocus)?
    private struct RecentAutomaticEdit {
        let focus: CombinedShiftFocus
        let inputRevision: UInt64
        let sessionID: UInt64
        let sourceLayoutID: String
        let resultLayoutID: String
        let receiptID: UUID?
    }
    private var recentAutomaticEdit: RecentAutomaticEdit?
    private var undoHeldFocus: (focus: CombinedShiftFocus, sourceLayoutID: String)?
    /// The one visible hint: verified field, caret and revision, never written
    /// until a double Shift accepts it. Any new typing, click or field change retires it.
    private var pendingHint: PendingCorrectionHint?
    private var hintExpiry: DispatchWorkItem?
    /// A hint left alone disappears on its own; an invisible hint never applies.
    var hintLifetime: TimeInterval = 6
    var latestHint: PredictionProposal? { pendingHint?.proposal }
    var onHintShown: ((PendingCorrectionHint) -> Void)?
    var onHintDismissed: ((CorrectionHintDismissal) -> Void)?
    /// Closed diagnostic codes of the hint, boundary and multi-word paths.
    var eventRecorder: (RuntimeDiagnosticEvent) -> Void = RuntimeDiagnostics.record
    /// AppDelegate supplies a saved choice. Legacy call sites default to off.
    var russianPriorityProvider: () -> Bool = { false }
    /// Exact displayed source phrase and language; storage belongs to the caller.
    var phraseExceptionLookup: (_ exactOriginal: String, _ sourceLanguage: String) -> Bool = { _, _ in false }
    var onCorrection: ((ConfirmedCorrectionNotice) -> Void)?
    /// T02 may present a nonactivating explicit exception offer after gesture undo.
    var onConfirmedAutomaticUndo: ((ConfirmedCorrectionNotice) -> Void)?
    var onAdaptiveAutomaticUndo: ((UUID, String, String, CombinedShiftFocus, UInt64) -> Void)?
    var adaptiveRulesProvider: () -> [AdaptiveRule] = { [] }
    var adaptiveGenerationProvider: () -> UInt64 = { 0 }
    var onApplied: ((String) -> Void)?
    var onUnconfirmedEdit: (() -> Void)?
    var onSourceFailure: ((String, LayoutSelectionCommit.Outcome?) -> Void)?
    /// Optional completion observer. Delivery follows already queued feedback;
    /// production leaves this nil and performs no extra work.
    var onEvaluationFinished: ((PredictionEvaluationID, PredictionEvaluationOutcome) -> Void)?
    /// Optional numeric stage for testing a queued caret-render retry.
    var onRenderRetryScheduled: ((PredictionEvaluationID) -> Void)?

    init(monitor: KeyboardMonitor, converter: TextConverter,
         platform: PredictionCoordinatorPlatform? = nil, engine: PredictionEngine? = nil,
         receiptNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         diagnosticsEnabled: @escaping () -> Bool = { RuntimeDiagnostics.enabled },
         loopGuard: AutoCorrectionLoopGuard = AutoCorrectionLoopGuard(),
         loopClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         recordAutomaticUncertain: @escaping (CombinedShiftApplicationFamily) -> Void = RuntimeDiagnostics.recordAutomaticUncertain) {
        self.monitor = monitor
        self.converter = converter
        self.platform = platform ?? .live(monitor: monitor)
        self.receiptNow = receiptNow
        self.diagnosticsEnabled = diagnosticsEnabled
        self.loopGuard = loopGuard
        self.loopClock = loopClock
        self.recordAutomaticUncertain = recordAutomaticUncertain
        self.correctionReceipts = ConfirmedCorrectionReceipts(now: receiptNow)
        if let engine {
            engineTask = Task { engine }
            readyEngine = engine
        } else {
            engineTask = Task.detached(priority: .utility) {
                guard let lexicon = try? PredictionLexicon.bundled() else {
                    RuntimeDiagnostics.record(.autoEngineUnavailable); return nil
                }
                RuntimeDiagnostics.record(.autoEngineReady)
                return PredictionEngine(lexicon: lexicon)
            }
        }
        monitor.beforePredictionText = { [weak self] processID, sourceLayoutID, text in
            self?.allowsPredictionTextDuringUndoHold(processID: processID,
                sourceLayoutID: sourceLayoutID, text: text) ?? true
        }
        if readyEngine == nil {
            let loading = engineTask
            Task { @MainActor [weak self] in
                let engine = await loading.value
                self?.readyEngine = engine
            }
        }
        monitor.onPredictionRevisionAdvanced = { [weak self] in
            guard let self, let hint = self.pendingHint,
                  hint.inputRevision != self.monitor.inputRevision else { return }
            self.clearHint(reason: .invalidated)
        }
        monitor.onConfirmedUndoHoldSourceChanged = { [weak self] sourceID in
            guard let self, let held = self.undoHeldFocus else { return }
            self.undoHeldFocus = (held.focus, sourceID)
        }
    }

    private func allowsPredictionTextDuringUndoHold(processID: Int32,
        sourceLayoutID: String, text: String) -> Bool {
        guard let held = undoHeldFocus else { return true }
        guard monitor.predictionIsWaitingForUndoBoundary,
              held.focus.processID == processID,
              held.sourceLayoutID == sourceLayoutID else {
            undoHeldFocus = nil
            return true // Existing source/PID reset handles the new input.
        }
        guard !platform.secureFlagBlocks(held.focus) else { return false }
        let currentElement: AXUIElement?
        if let focusedIdentity = platform.focusedIdentity {
            currentElement = focusedIdentity(processID)
        } else {
            // Synthetic platform fixtures retain their existing focus seam.
            currentElement = platform.captureFocus(processID)?.element
        }
        guard let currentElement else {
            RuntimeDiagnostics.record(.autoFocusAnchorUnavailable)
            if text.last?.isWhitespace == true {
                // This packet closes the unknown current word. End the old hold
                // without scoring any part of it; the next word must capture
                // its own exact field and caret. A trailing partial word stays held.
                undoHeldFocus = nil
                monitor.resetPredictionContext()
            }
            return false
        }
        if !CFEqual(currentElement, held.focus.element) {
            undoHeldFocus = nil
            monitor.resetPredictionContext()
            return true // The next snapshot captures this new field normally.
        }
        if text.contains(where: \.isWhitespace) { undoHeldFocus = nil }
        return true
    }

    /// Reuse the already-loading immutable RU/EN corpus. SQLite may fault or
    /// return unavailable, so every exact lookup runs away from MainActor and
    /// a missing answer refuses the whole selected edit.
    func nativeSelectionEvidence(for queries: [SmartConvert.WordQuery],
        protectedWord: @escaping @Sendable (PredictionLexicon, String, String) -> Bool = {
            $0.isProtectedTerm($1, language: $2)
        }) async
        -> [SmartConvert.WordQuery: Bool]? {
        guard let engine = await engineTask.value else { return nil }
        return await Task.detached(priority: .userInitiated) {
            var answer: [SmartConvert.WordQuery: Bool] = [:]
            for query in queries {
                guard let frequency = engine.lexicon.fullFrequency(of: query.word,
                    language: query.language),
                    let spelling = engine.lexicon.hasSupplementalSpelling(query.word,
                        language: query.language) else { return nil }
                answer[query] = frequency > 0 || protectedWord(engine.lexicon,
                    query.word, query.language) || spelling
            }
            return answer
        }.value
    }

    /// The visible hint for exactly this field, caret and current input revision.
    func currentHint(for focus: CombinedShiftFocus) -> PendingCorrectionHint? {
        guard let pendingHint, pendingHint.matches(focus: focus, inputRevision: monitor.inputRevision)
        else { return nil }
        return pendingHint
    }

    func clearHint(reason: CorrectionHintDismissal) {
        hintExpiry?.cancel(); hintExpiry = nil
        guard pendingHint != nil else { return }
        pendingHint = nil
        onHintDismissed?(reason)
    }

    private func showHint(_ hint: PendingCorrectionHint) {
        if pendingHint != nil { clearHint(reason: .replaced) }
        pendingHint = hint
        eventRecorder(.hintShown)
        onHintShown?(hint)
        let expiry = DispatchWorkItem { [weak self] in self?.clearHint(reason: .expired) }
        hintExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + hintLifetime, execute: expiry)
    }

    /// Double Shift asks here before its ordinary path. nil means no visible
    /// hint for this gesture's field, caret, revision and layout pair: the
    /// ordinary conversion runs. Otherwise exactly the hint is written through
    /// the verified suffix path, or nothing at all.
    func acceptHint(request: CombinedShiftRequest, context: CombinedShiftContext) -> CorrectionHintAcceptance? {
        guard let focus = request.focus, request.inputRevision == monitor.inputRevision,
              let hint = currentHint(for: focus),
              context.sourceLayoutID == hint.sourceLayoutID,
              context.targetLayoutID == hint.resultLayoutID else { return nil }
        clearHint(reason: .accepted)
        guard hint.writableAtCollapsedCaret else {
            eventRecorder(.typoLengthChangeRefused)
            return .refused
        }
        guard request.frontProcessID == focus.processID,
              platform.frontmost().processID == focus.processID,
              !platform.secureFlagBlocks(focus), !platform.remoteDeferred(),
              platform.focusIsCurrent(focus),
              !converter.hasUnconfirmedAXEdit(in: focus) else {
            eventRecorder(.hintRefused)
            return .refused
        }
        // Manual gesture: no loop guard, and the field revision alone (not the
        // prediction generation the first Shift's source change advanced) binds it.
        let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: hint.inputRevision,
            currentInputRevision: { [weak monitor] in monitor?.inputRevision ?? UInt64.max })
        let outcome = write(VerifiedWrite(proposal: hint.proposal, edit: hint.edit, focus: focus,
            processID: focus.processID, inputRevision: hint.inputRevision,
            sourceLayoutID: hint.sourceLayoutID, resultLayoutID: hint.resultLayoutID,
            sourceLanguage: hint.sourceLanguage), execution: execution, automatic: false)
        switch outcome {
        case .applied:
            eventRecorder(.hintAccepted)
            return .confirmed
        case .sourceUnconfirmed:
            return .sourceNotConfirmed(targetID: hint.resultLayoutID)
        case .textUnconfirmed:
            return .unknown
        default:
            eventRecorder(.hintRefused)
            return .refused
        }
    }

    // MARK: Several words in the wrong layout

    private var readyEngine: PredictionEngine?

    /// Synchronous in-memory evidence for the multi-word double Shift: the
    /// typed word is unknown in its own language and common in the other one.
    /// Before the dictionaries have loaded the answer is always no.
    func prefersOtherLayout(original: String, converted: String, sourceLanguage: String) -> Bool {
        guard let lexicon = readyEngine?.lexicon else { return false }
        let source = String(sourceLanguage.lowercased().prefix(2))
        guard source == "ru" || source == "en" else { return false }
        let target = source == "en" ? "ru" : "en"
        let word = PredictionLexicon.normalize(original)
        let mapped = PredictionLexicon.normalize(converted)
        guard word != mapped, mapped.contains(where: \.isLetter) else { return false }
        return lexicon.frequency(of: word, language: source) == 0
            && lexicon.frequency(of: mapped, language: target) >= Self.multiWordMinimumFrequency
    }

    static let multiWordMinimumFrequency = 500

    // MARK: Enter/Tab as a word boundary

    private var boundaryKeyHold: BoundaryKeyHold? { monitor.boundaryKeyHold }
    private var boundaryEvaluation: Task<Void, Never>?

    /// Main, inside the Enter/Tab callback. Only a current word with its
    /// event-time field anchor may hold the key; everything else declines and
    /// the key goes at once. Only a confident `apply` writes, never a hint.
    func correctBeforeBoundaryKey(_ snapshot: PredictionSnapshot, ticket: BoundaryKeyHold.Ticket) -> Bool {
        guard snapshot.atBoundary, anchorSessionID == snapshot.sessionID, anchorFocus != nil,
              pendingCaretAnchor != nil, !anchorProofDeferred, isCurrent(snapshot) else { return false }
        boundaryEvaluation?.cancel()
        boundaryEvaluation = Task { [weak self] in
            await self?.evaluate(snapshot, evaluationID: nil, boundaryHold: ticket)
        }
        return true
    }

    private func finishBoundaryHold(_ ticket: BoundaryKeyHold.Ticket, outcome: PredictionEvaluationOutcome) {
        if outcome == .applied { eventRecorder(.boundaryKeyCorrected) }
        onBoundaryHoldFinished?(outcome)
        monitor.finishBoundaryHold(ticket)
    }

    /// Test observation of a held boundary key's outcome; production leaves it nil.
    var onBoundaryHoldFinished: ((PredictionEvaluationOutcome) -> Void)?

    func invalidate() {
        if !monitor.predictionIsWaitingForUndoBoundary { undoHeldFocus = nil }
        // The first Shift's own source change resets prediction without any
        // input; the hint survives that only while the input revision is unchanged.
        if let pendingHint, pendingHint.inputRevision != monitor.inputRevision {
            clearHint(reason: .invalidated)
        }
        debounce?.cancel(); debounce = nil
        if let pendingDebounceID {
            self.pendingDebounceID = nil
            reportEvaluationFinished(pendingDebounceID, .cancelledBeforeEvaluation)
        }
        evaluation?.cancel(); evaluation = nil
    }

    private func reportEvaluationFinished(_ evaluationID: PredictionEvaluationID,
                                          _ outcome: PredictionEvaluationOutcome) {
        guard onEvaluationFinished != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.onEvaluationFinished?(evaluationID, outcome) }
    }

    func submit(_ snapshot: PredictionSnapshot) {
        // New typed text continues past the offered word.
        clearHint(reason: .typing)
        invalidate()
        let evaluationID: PredictionEvaluationID?
        if onEvaluationFinished != nil {
            nextEvaluationSequence &+= 1
            evaluationID = PredictionEvaluationID(snapshot, sequence: nextEvaluationSequence)
        } else {
            evaluationID = nil
        }
        latestSubmittedEvaluationID = evaluationID
        let bundleID = platform.frontmost().bundleID
        let route = platform.route(bundleID, snapshot.suffix, snapshot.sourceLayoutID)
        guard route != .blocked, !platform.deniedApp(bundleID) || route == .nativeCanary else {
            anchorSessionID = nil; anchorFocus = nil; pendingCaretAnchor = nil
            anchorProofDeferred = false
            if let evaluationID { reportEvaluationFinished(evaluationID, .notScheduled) }
            return // blocked editors must not incur a synchronous AX capture
        }
        if anchorProofDeferred, anchorSessionID == snapshot.sessionID, snapshot.atBoundary {
            // A newer physical separator superseded an unresolved render retry.
            // Do not let its cancelled task keep this word's event-time anchor.
            retireFailedCaretAnchor(snapshot, fromBoundaryEvent: true)
            if let evaluationID { reportEvaluationFinished(evaluationID, .notScheduled) }
            return
        }
        if anchorSessionID != snapshot.sessionID {
            RuntimeDiagnostics.record(.autoAnchorSessionChanged)
            anchorSessionID = snapshot.sessionID
            anchorFocus = nil
            pendingCaretAnchor = nil
            anchorProofDeferred = false
            captureOriginalAnchor(snapshot)
        }
        if anchorFocus == nil, snapshot.atBoundary {
            // A failed first-event AX capture cannot be repaired later in this
            // word: another field could have acquired focus. End the failed
            // session only after its word boundary. The next word starts with
            // a fresh event-time field and caret anchor.
            monitor.resetPredictionContext()
            if let evaluationID { reportEvaluationFinished(evaluationID, .notScheduled) }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let evaluationID, self.pendingDebounceID == evaluationID { self.pendingDebounceID = nil }
            RuntimeDiagnostics.record(.autoWorkStarted)
            self.evaluation = Task { [weak self] in await self?.evaluate(snapshot, evaluationID: evaluationID) }
        }
        debounce = work
        pendingDebounceID = evaluationID
        // The original key must reach the destination before AX suffix verification.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(snapshot.atBoundary ? 12 : 70), execute: work)
    }

    private func captureOriginalAnchor(_ snapshot: PredictionSnapshot) {
        // Capture before returning the first callback, rather than letting a later
        // queued capture become stale after a burst. Unknown focus stays unavailable;
        // a subsequent proposal must never establish a different field as baseline.
        guard !platform.searchOverlayActive(),
              snapshot.sessionID == monitor.predictionSessionID,
              snapshot.isCurrent(processID: platform.frontmost().processID,
                  revision: monitor.inputRevision, generation: monitor.predictionGeneration) else {
            RuntimeDiagnostics.record(.autoAnchorStale); return
        }
        guard let focus = platform.captureFocus(snapshot.processID) else {
            RuntimeDiagnostics.record(.autoAnchorUnavailable); return
        }
        // The capture reads only the selected range, itself refused under the
        // raised flag for anything but an ordinary non-holder field.
        guard !platform.secureFlagBlocks(focus) else {
            RuntimeDiagnostics.record(.autoAnchorStale); return
        }
        guard let selection = focus.initialSelection, selection.length == 0,
              let pending = PredictionPendingCaretAnchor(sessionID: snapshot.sessionID,
                  caretUTF16Location: selection.location, inputUTF16Offset: snapshot.cumulativeUTF16Offset,
                  eventUTF16Length: snapshot.eventUTF16Length) else {
            RuntimeDiagnostics.record(.autoAnchorSelectionUnavailable); return
        }
        anchorFocus = focus
        pendingCaretAnchor = pending
        RuntimeDiagnostics.record(.autoAnchorAccepted)
    }

    private func retryRenderVerification(_ snapshot: PredictionSnapshot, attempt: Int,
                                         evaluationID: PredictionEvaluationID?) -> Bool {
        // AX may briefly lag the event queue. Retry only this current snapshot and
        // original field; a new key, focus reset or explicit cancellation stops it.
        guard attempt < 3, isCurrent(snapshot) else { return false }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let evaluationID, self.pendingDebounceID == evaluationID { self.pendingDebounceID = nil }
            self.evaluation = Task { [weak self] in
                await self?.evaluate(snapshot, evaluationID: evaluationID, renderAttempt: attempt + 1)
            }
        }
        debounce = work
        pendingDebounceID = evaluationID
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15), execute: work)
        if let evaluationID { onRenderRetryScheduled?(evaluationID) }
        return true
    }

    private func retireFailedCaretAnchor(_ snapshot: PredictionSnapshot,
                                         fromBoundaryEvent: Bool = false) {
        // A bounded proof failure cannot authorize edits in this session. Keep
        // the open token unscored, and only let a later physical separator (or
        // this already observed separator) start a new event-time capture.
        guard anchorSessionID == snapshot.sessionID else { return }
        if fromBoundaryEvent {
            // A newer event can be submitted synchronously from the old retry
            // callback. That callback cancels its own task during invalidate(),
            // so Task.isCancelled says nothing about the newer physical event.
            guard snapshot.sessionID == monitor.predictionSessionID,
                  snapshot.isCurrent(processID: platform.frontmost().processID,
                      revision: monitor.inputRevision, generation: monitor.predictionGeneration) else { return }
        } else {
            guard isCurrent(snapshot) else { return }
        }
        anchorFocus = nil
        pendingCaretAnchor = nil
        anchorProofDeferred = false
        RuntimeDiagnostics.record(.autoAnchorStale)
        RuntimeDiagnostics.record(.autoAnchorRetired)
        if snapshot.atBoundary { monitor.resetPredictionContext() }
    }

    private func isCurrent(_ snapshot: PredictionSnapshot) -> Bool {
        if platform.secureFlagBlocks(anchorFocus) {
            monitor.resetPredictionContext()
            return false
        }
        let bundleID = platform.frontmost().bundleID
        let route = platform.route(bundleID, snapshot.suffix, snapshot.sourceLayoutID)
        guard route != .blocked else { RuntimeDiagnostics.record(.nativeAutoBlocked); return false }
        return !Task.isCancelled && platform.autoSwitchEnabled() && platform.autoConvertEnabled()
            && snapshot.sourceLayoutID == platform.currentLayoutID()
            && !platform.remoteDeferred()
            && (!platform.deniedApp(bundleID) || route == .nativeCanary)
            && snapshot.sessionID == monitor.predictionSessionID
            && snapshot.isCurrent(processID: platform.frontmost().processID,
                revision: monitor.inputRevision, generation: monitor.predictionGeneration)
    }

    private func evaluate(_ snapshot: PredictionSnapshot, evaluationID: PredictionEvaluationID?,
                          renderAttempt: Int = 0, boundaryHold: BoundaryKeyHold.Ticket? = nil) async {
        var outcome: PredictionEvaluationOutcome = .refused
        var retryScheduled = false
        defer {
            if !retryScheduled, let evaluationID { reportEvaluationFinished(evaluationID, outcome) }
            if let boundaryHold { finishBoundaryHold(boundaryHold, outcome: outcome) }
        }
        guard isCurrent(snapshot) else { outcome = .stale; RuntimeDiagnostics.record(.autoEvaluationStale); return }
        guard let engine = await engineTask.value else { outcome = .engineUnavailable; RuntimeDiagnostics.record(.autoEngineUnavailable); return }
        guard isCurrent(snapshot) else { outcome = .stale; RuntimeDiagnostics.record(.autoEvaluationStale); return }
        guard let source = LayoutSwitcher.installedLayouts().first(where: {
                  LayoutSwitcher.sourceID($0) == snapshot.sourceLayoutID
              }), let language = LayoutSwitcher.languageCode(source),
              let pair = LayoutSwitcher.combinedShiftContext(sourceLayoutID: snapshot.sourceLayoutID),
              let opposite = LayoutSwitcher.installedLayouts().first(where: {
                  LayoutSwitcher.sourceID($0) == pair.targetLayoutID
              }), let oppositeLanguage = LayoutSwitcher.languageCode(opposite),
              Set([String(language.prefix(2)), String(oppositeLanguage.prefix(2))]) == Set(["ru", "en"]) else {
            outcome = .mappingUnavailable; RuntimeDiagnostics.record(.autoMappingUnavailable); return
        }
        let characterMapping = DynamicKeyMapping.buildMap(from: source, to: opposite)
        guard !characterMapping.isEmpty else { outcome = .mappingUnavailable; RuntimeDiagnostics.record(.autoMappingUnavailable); return }
        let alwaysConvertWords = SettingsManager.shared.alwaysConvertWordsSet
        let russianPriority = russianPriorityProvider()
        let adaptiveRules = adaptiveRulesProvider()
        let decision = await Task.detached(priority: .userInitiated) {
            engine.evaluate(suffix: snapshot.suffix, sourceLanguage: language,
                atBoundary: snapshot.atBoundary, precedingWords: snapshot.precedingWords,
                alwaysConvertWords: alwaysConvertWords, characterMapping: characterMapping,
                russianPriority: russianPriority, adaptiveRules: adaptiveRules)
        }.value
        guard isCurrent(snapshot) else { outcome = .stale; RuntimeDiagnostics.record(.autoEvaluationStale); return }
        let proposal: PredictionProposal
        let isHint: Bool
        switch decision {
        case .none:
            outcome = .noProposal; RuntimeDiagnostics.record(.autoNoProposal); return
        case .hint(let offered):
            // A boundary key never waits for a doubtful word.
            guard boundaryHold == nil else { outcome = .noProposal; return }
            // Verified like an edit below, then only shown: never written here.
            proposal = offered; isHint = true
        case .apply(let applied):
            proposal = applied; isHint = false
        }
        // A floating search field may acquire input after this word's first
        // event. Never commit a proposal to the stale underlay anchor.
        guard !platform.searchOverlayActive() else { outcome = .stale; return }
        if !isHint { RuntimeDiagnostics.record(.autoProposal) }
        guard proposal.originalSuffix == snapshot.suffix,
              !Self.containsDeniedChange(original: proposal.originalSuffix, replacement: proposal.replacementSuffix),
              !phraseExceptionLookup(proposal.originalSuffix, String(language.lowercased().prefix(2))) else {
            outcome = .rejected; RuntimeDiagnostics.record(.autoProposalRejected); return
        }
        guard let target = LayoutSwitcher.installedLayouts().first(where: {
                  [pair.sourceLayoutID, pair.targetLayoutID].contains(LayoutSwitcher.sourceID($0))
                      && LayoutSwitcher.languageCode($0)?.lowercased().hasPrefix(proposal.targetLanguage) == true
              }) else { RuntimeDiagnostics.record(.autoTargetUnavailable); return }
        guard let originalFocus = anchorFocus else { RuntimeDiagnostics.record(.autoFocusAnchorUnavailable); return }
        guard PredictionFocusAnchorPolicy.permits(originalSession: anchorSessionID,
                  currentSession: snapshot.sessionID, capturedOriginalField: true,
                  sameField: platform.focusIsCurrent(originalFocus)) else {
            // The old field can no longer authorize this session. The boundary
            // will discard its word before a fresh event captures another field.
            anchorFocus = nil
            pendingCaretAnchor = nil
            RuntimeDiagnostics.record(.autoFocusMismatch); return
        }
        guard var pending = pendingCaretAnchor else {
            RuntimeDiagnostics.record(.autoCaretUnavailable); return
        }
        guard let currentSelection = originalFocus.selectionRange() else {
            RuntimeDiagnostics.record(.autoCaretUnavailable)
            anchorProofDeferred = true
            retryScheduled = boundaryHold == nil
                && retryRenderVerification(snapshot, attempt: renderAttempt, evaluationID: evaluationID)
            if !retryScheduled && renderAttempt >= 3 {
                outcome = .renderRetryExhausted
                retireFailedCaretAnchor(snapshot)
            }
            return
        }
        // Retain the first session's field identity; only its current collapsed
        // caret is refreshed. A same-PID different field is never a new baseline.
        let focus = CombinedShiftFocus(processID: originalFocus.processID, element: originalFocus.element,
            initialSelection: currentSelection, fieldBoundary: originalFocus.fieldBoundary)
        let suffixMatches = focus.hasOriginalSuffixBeforeCaret(snapshot.suffix)
        let resolved = pending.resolve(sessionID: snapshot.sessionID, location: currentSelection.location,
            selectionLength: currentSelection.length, cumulativeOffset: snapshot.cumulativeUTF16Offset,
            sameField: platform.focusIsCurrent(originalFocus), snapshotIsCurrent: isCurrent(snapshot), suffixMatches: suffixMatches)
        if pending.isCancelled {
            anchorFocus = nil
            pendingCaretAnchor = nil
            anchorProofDeferred = false
            RuntimeDiagnostics.record(.autoFocusMismatch)
            return
        }
        pendingCaretAnchor = pending
        guard resolved != nil else {
            RuntimeDiagnostics.record(.autoCaretMismatch)
            anchorProofDeferred = true
            retryScheduled = boundaryHold == nil
                && retryRenderVerification(snapshot, attempt: renderAttempt, evaluationID: evaluationID)
            if !retryScheduled && renderAttempt >= 3 {
                outcome = .renderRetryExhausted
                retireFailedCaretAnchor(snapshot)
            }
            return
        }
        anchorProofDeferred = false
        guard isCurrent(snapshot) else { outcome = .stale; RuntimeDiagnostics.record(.autoEvaluationStale); return }
        guard let edit = PredictionSuffixEdit(original: proposal.originalSuffix,
            replacement: proposal.replacementSuffix) else { return }
        let verified = VerifiedWrite(proposal: proposal, edit: edit, focus: focus,
            processID: snapshot.processID, inputRevision: snapshot.inputRevision,
            sourceLayoutID: snapshot.sourceLayoutID, resultLayoutID: LayoutSwitcher.sourceID(target),
            sourceLanguage: String(language.lowercased().prefix(2)))
        if isHint {
            // An unknown earlier edit in this field keeps the hint hidden.
            guard !converter.hasUnconfirmedAXEdit(in: focus) else { return }
            let hint = PendingCorrectionHint(proposal: proposal, edit: edit, focus: focus,
                caretUTF16Location: currentSelection.location, inputRevision: snapshot.inputRevision,
                sessionID: snapshot.sessionID, sourceLayoutID: verified.sourceLayoutID,
                resultLayoutID: verified.resultLayoutID, sourceLanguage: verified.sourceLanguage,
                issuedAt: receiptNow())
            // Never offer what double Shift cannot apply: the ordinary path stays.
            guard hint.writableAtCollapsedCaret else { outcome = .noProposal; return }
            showHint(hint)
            outcome = .hinted
            return
        }
        // The converter must preserve an unknown edit in this exact AX field.
        // Refuse before opening another input lease or recording a source window;
        // a different field remains eligible for its own verified edit.
        guard !converter.hasUnconfirmedAXEdit(in: focus) else {
            RuntimeDiagnostics.record(.unconfirmedEditBlocked)
            RuntimeDiagnostics.record(.autoEditRefused)
            DispatchQueue.main.async { [weak self] in self?.onUnconfirmedEdit?() }
            return
        }
        // Manual double Shift never passes through here, so it is never paused.
        guard loopGuard.allow(now: loopClock(), original: proposal.originalSuffix,
                              replacement: proposal.replacementSuffix) else {
            outcome = .suppressed; return
        }
        let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: snapshot.inputRevision,
            currentInputRevision: { [weak monitor] in
                guard let monitor, monitor.predictionGeneration == snapshot.generation else { return UInt64.max }
                return monitor.inputRevision
            })
        outcome = write(verified, execution: execution, automatic: true, mayBeginWrite: {
            boundaryHold.map { boundaryKeyHold?.beginWrite($0) == true } ?? true
        })
    }

    /// The single verified write shared by automatic correction, an accepted
    /// hint and a held boundary key. Every caller has verified field and caret.
    private struct VerifiedWrite {
        let proposal: PredictionProposal
        let edit: PredictionSuffixEdit
        let focus: CombinedShiftFocus
        let processID: Int32
        let inputRevision: UInt64
        let sourceLayoutID: String
        let resultLayoutID: String
        let sourceLanguage: String
    }

    private func write(_ verified: VerifiedWrite, execution: CombinedShiftExecutionContext,
                       automatic: Bool, mayBeginWrite: () -> Bool = { true }) -> PredictionEvaluationOutcome {
        var outcome: PredictionEvaluationOutcome = .refused
        let proposal = verified.proposal, edit = verified.edit, focus = verified.focus
        let resultID = verified.resultLayoutID
        guard mayBeginWrite() else { return .refused }
        guard let lease = platform.beginLease(verified.processID) else {
            RuntimeDiagnostics.record(.nativeFenceUnavailable); return .refused
        }
        var requestedAt: UInt64 = 0
        let securePermit = SecureFlagFieldPermit(focus: focus, flagRaised: { [platform] in
            platform.secureFlagRaised()
        })
        let sourceCommit = NativeQueuedSourceCommit(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.platform.leaseIsCurrent(lease)
                && self.monitor.inputRevision == verified.inputRevision
                && self.platform.frontmost().processID == verified.processID
                && securePermit.allows()
        }, request: { target in
            requestedAt = self.platform.sourceRequestedAt()
            return self.platform.selectSource(target)
        }, onUnconfirmed: { target in
            self.platform.noteUnconfirmedSource(target, requestedAt)
        })
        var queuedUnknown = false
        defer {
            platform.finishLease(lease, sourceCommit.confirmedLayoutID)
            if queuedUnknown && diagnosticsEnabled() {
                // This only runs for an unknown queued edit, after the input
                // lease ends. Frontmost metadata is never read for successful edits.
                let front = platform.frontmost()
                let family = RuntimeDiagnostics.applicationFamily(bundleID: front.bundleID,
                    expectedProcessID: verified.processID, observedProcessID: front.processID,
                    secureInputActive: platform.secureFlagRaised() || focus.processID != verified.processID,
                    diagnosticsEnabled: true)
                recordAutomaticUncertain(family)
            }
        }
        var textWasQueued = false
        let textConfirmed = converter.withNativeInputBudget({ [weak self] in
            self?.platform.leaseRemaining(lease)
        }) {
            converter.withNativeTextQueuedHandler({ target in
                guard target == resultID else { return }
                textWasQueued = true
            }) {
                converter.replaceVerifiedSuffix(original: edit.original,
                    replacement: edit.replacement, sourceLayoutID: verified.sourceLayoutID,
                    resultLayoutID: resultID, execution: execution,
                    inputBarrierIsActive: { [weak self] in
                        self?.platform.leaseIsCurrent(lease) == true
                    })
            }
        }
        guard textConfirmed else {
            if converter.hasUnconfirmedAXEdit(in: focus) {
                // Let the lease finish before showing a nonactivating notice.
                DispatchQueue.main.async { [weak self] in self?.onUnconfirmedEdit?() }
            }
            if textWasQueued {
                queuedUnknown = true
                monitor.resetPredictionContext()
                outcome = .textUnconfirmed
                RuntimeDiagnostics.record(.autoTextUnconfirmed)
            } else {
                RuntimeDiagnostics.record(.autoEditRefused)
            }
            return outcome
        }
        RuntimeDiagnostics.record(.autoTextConfirmed)
        if automatic {
            loopGuard.record(original: proposal.originalSuffix,
                replacement: proposal.replacementSuffix, now: loopClock())
        }
        // Physical input is still held by this lease. Select the result source
        // only after the complete field edit is independently acknowledged.
        // Queued Unicode alone can still be dropped or delivered late.
        sourceCommit.textQueued(targetID: resultID)
        let wholeField = converter.confirmedAutomaticField
        guard sourceCommit.outcome == .confirmed, platform.leaseIsCurrent(lease) else {
            // The field has the confirmed replacement. Keep TextConverter undo,
            // discard stale typed buffers, and wait for an actual source read.
            monitor.markConverted()
            monitor.requireObservedInputSource(resultID)
            let notice = wholeField.flatMap {
                retainReceipt(proposal: proposal, edit: edit, focus: focus,
                    sourceLanguage: verified.sourceLanguage,
                    sourceLayoutID: verified.sourceLayoutID, resultLayoutID: resultID,
                    field: $0)
            }
            rememberAutomaticEdit(focus: focus, sourceLayoutID: verified.sourceLayoutID,
                resultLayoutID: resultID, receiptID: notice?.id)
            let sourceOutcome = sourceCommit.outcome
            DispatchQueue.main.async { [weak self] in
                self?.onSourceFailure?(resultID, sourceOutcome)
            }
            RuntimeDiagnostics.record(sourceCommit.outcome == .unconfirmed ? .autoSourceUnconfirmed : .autoSourceFailed)
            outcome = .sourceUnconfirmed
            return outcome
        }
        RuntimeDiagnostics.record(.autoSourceConfirmed)
        monitor.recordPredictionResult(original: proposal.originalSuffix,
            replacement: proposal.replacementSuffix, resultLayoutID: resultID)
        RuntimeDiagnostics.record(.autoEditPosted)
        let notice = wholeField.flatMap {
            retainReceipt(proposal: proposal, edit: edit, focus: focus,
               sourceLanguage: verified.sourceLanguage,
               sourceLayoutID: verified.sourceLayoutID, resultLayoutID: resultID,
               field: $0)
        }
        rememberAutomaticEdit(focus: focus, sourceLayoutID: verified.sourceLayoutID,
            resultLayoutID: resultID, receiptID: notice?.id)
        if let notice {
            // Present feedback only after the input fence has been released.
            DispatchQueue.main.async { [weak self] in self?.onCorrection?(notice) }
        }
        let changedWord = zip(proposal.originalSuffix.split(whereSeparator: \.isWhitespace),
                              proposal.replacementSuffix.split(whereSeparator: \.isWhitespace))
            .first(where: { $0 != $1 }).map { String($0.0) } ?? edit.original
        onApplied?(changedWord)
        if automatic, let notice {
            monitor.armImplicitUndo(id: notice.id, corrected: edit.replacement,
                original: edit.original, processID: verified.processID)
        }
        return .applied
    }

    @discardableResult
    private func retainReceipt(proposal: PredictionProposal, edit: PredictionSuffixEdit,
                               focus: CombinedShiftFocus, sourceLanguage: String,
                               sourceLayoutID: String, resultLayoutID: String,
                               field: (before: NativeFieldObservation, after: NativeFieldObservation))
                               -> ConfirmedCorrectionNotice? {
        let notice = ConfirmedCorrectionNotice(id: UUID(), original: proposal.originalSuffix,
            replacement: proposal.replacementSuffix, sourceLanguage: sourceLanguage)
        let receipt = ConfirmedCorrectionReceipt(notice: notice, focus: focus,
            inputRevision: monitor.inputRevision, sessionID: monitor.predictionSessionID,
            sourceLayoutID: sourceLayoutID, resultLayoutID: resultLayoutID,
            editOriginal: edit.original, editReplacement: edit.replacement,
            before: field.before, after: field.after,
            issuedAt: receiptNow())
        return correctionReceipts.retain(receipt) ? notice : nil
    }

    private func rememberAutomaticEdit(focus: CombinedShiftFocus, sourceLayoutID: String,
                                       resultLayoutID: String, receiptID: UUID?) {
        if receiptID == nil { correctionReceipts.retireGestureCandidate() }
        recentAutomaticEdit = RecentAutomaticEdit(focus: focus,
            inputRevision: monitor.inputRevision, sessionID: monitor.predictionSessionID,
            sourceLayoutID: sourceLayoutID, resultLayoutID: resultLayoutID,
            receiptID: receiptID)
    }

    /// Called after the first solo Shift selected the original source. Metadata
    /// only selects the undo branch; TextConverter compares the exact whole field
    /// again under the transaction's input lease before writing anything.
    func claimDoubleShiftAutomaticUndo(request: CombinedShiftRequest,
        context: CombinedShiftContext, observedSourceID: String) -> DoubleShiftAutomaticUndo {
        guard let recent = recentAutomaticEdit, let focus = request.focus,
              request.frontProcessID == recent.focus.processID,
              focus.processID == recent.focus.processID,
              CFEqual(focus.element, recent.focus.element),
              request.inputRevision == recent.inputRevision,
              monitor.inputRevision == recent.inputRevision else { return .manual }
        guard focus.initialSelection?.length == 0 else { return .manual }
        guard monitor.predictionSessionID == recent.sessionID,
              !platform.secureFlagBlocks(focus), !platform.remoteDeferred(),
              !platform.deniedApp(platform.frontmost().bundleID),
              platform.frontmost().processID == focus.processID,
              platform.focusIsCurrent(focus),
              !converter.hasUnconfirmedAXEdit(in: focus),
              context.sourceLayoutID == recent.resultLayoutID,
              context.targetLayoutID == recent.sourceLayoutID,
              observedSourceID == recent.sourceLayoutID,
              let id = recent.receiptID,
              let receipt = correctionReceipts.claimForGesture(id) else { return .staleAutomatic }
        guard receipt.inputRevision == recent.inputRevision,
              receipt.sessionID == recent.sessionID,
              receipt.focus.processID == focus.processID,
              CFEqual(receipt.focus.element, focus.element),
              receipt.sourceLayoutID == recent.sourceLayoutID,
              receipt.resultLayoutID == recent.resultLayoutID,
              let selection = focus.selectionRange(),
              selection.location == receipt.after.caretUTF16Location,
              selection.length == receipt.after.selectionLength else { return .staleAutomatic }
        return .receipt(receipt)
    }

    /// The transaction has already released its lease and confirmed both text
    /// and source. The notice contains no AX element or whole-field contents.
    func completeDoubleShiftAutomaticUndo(_ receipt: ConfirmedCorrectionReceipt) {
        recentAutomaticEdit = nil
        let atBoundary = Self.undoIsAtBoundary(receipt.before)
        monitor.beginPredictionWordAfterConfirmedUndo(processID: receipt.focus.processID,
            sourceLayoutID: receipt.sourceLayoutID,
            atBoundary: atBoundary)
        undoHeldFocus = atBoundary ? nil : (receipt.focus, receipt.sourceLayoutID)
        onConfirmedAutomaticUndo?(receipt.notice)
        onAdaptiveAutomaticUndo?(receipt.notice.id, receipt.editReplacement, receipt.editOriginal,
            receipt.focus, adaptiveGenerationProvider())
    }

    /// The ID is consumed before attempting a mutation. UI actions never select
    /// a remembered range or reuse current selection as a new target.
    func undoCorrection(id: UUID, completion: @escaping (CorrectionUndoResult) -> Void) {
        confirmedAdaptiveUndo = nil
        let result = performUndoCorrection(id: id)
        // performUndoCorrection has released its input lease before this call.
        if case .confirmed = result, let event = confirmedAdaptiveUndo {
            onAdaptiveAutomaticUndo?(event.id, event.original, event.replacement, event.focus,
                adaptiveGenerationProvider())
        }
        confirmedAdaptiveUndo = nil
        completion(result)
    }

    private func performUndoCorrection(id: UUID) -> CorrectionUndoResult {
        guard let receipt = correctionReceipts.claim(id) else { return .refused }
        let focus = receipt.focus
        guard !platform.secureFlagBlocks(focus), !platform.remoteDeferred(),
              !platform.deniedApp(platform.frontmost().bundleID),
              platform.frontmost().processID == focus.processID,
              platform.focusIsCurrent(focus),
              monitor.inputRevision == receipt.inputRevision,
              monitor.predictionSessionID == receipt.sessionID,
              platform.currentLayoutID() == receipt.resultLayoutID,
              !converter.hasUnconfirmedAXEdit(in: focus),
              let currentSelection = focus.selectionRange(),
              currentSelection.location == receipt.after.caretUTF16Location,
              currentSelection.length == receipt.after.selectionLength,
              let lease = platform.beginLease(focus.processID) else { return .refused }
        var requestedAt: UInt64 = 0
        let securePermit = SecureFlagFieldPermit(focus: focus, flagRaised: { [platform] in
            platform.secureFlagRaised()
        })
        let sourceCommit = NativeQueuedSourceCommit(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.platform.leaseIsCurrent(lease)
                && self.monitor.inputRevision == receipt.inputRevision
                && self.platform.frontmost().processID == focus.processID
                && securePermit.allows()
        }, request: { [weak self] target in
            guard let self else { return .refused }
            requestedAt = self.platform.sourceRequestedAt()
            return self.platform.selectSource(target)
        }, onUnconfirmed: { [weak self] target in
            self?.platform.noteUnconfirmedSource(target, requestedAt)
        })
        defer { platform.finishLease(lease, sourceCommit.confirmedLayoutID) }
        let currentFocus = CombinedShiftFocus(processID: focus.processID, element: focus.element,
            initialSelection: currentSelection, fieldBoundary: focus.fieldBoundary)
        let execution = CombinedShiftExecutionContext(focus: currentFocus,
            inputRevision: receipt.inputRevision,
            currentInputRevision: { [weak monitor] in monitor?.inputRevision ?? UInt64.max })
        converter.beginManualTransaction()
        let result = converter.withNativeInputBudget({ [weak self] in
            self?.platform.leaseRemaining(lease)
        }) {
            converter.withNativeTextQueuedHandler({ _ in
                // A queue receipt cannot select a source for an unknown undo.
            }) {
                converter.undoConfirmedCorrection(receipt, execution: execution,
                    inputBarrierIsActive: { [weak self] in
                        self?.platform.leaseIsCurrent(lease) == true
                    })
            }
        }
        switch result {
        case .refused:
            return .refused
        case .unknown:
            return .unknown
        case .confirmed:
            sourceCommit.textQueued(targetID: receipt.sourceLayoutID)
            guard sourceCommit.outcome == .confirmed, platform.leaseIsCurrent(lease) else {
                monitor.markConverted()
                monitor.requireObservedInputSource(receipt.sourceLayoutID)
                return .sourceNotConfirmed(targetID: receipt.sourceLayoutID)
            }
            if let field = converter.confirmedNativeField,
               field.focus.processID == focus.processID,
               CFEqual(field.focus.element, focus.element) {
                monitor.adoptConfirmedManualField(field, resultLayoutID: receipt.sourceLayoutID)
                let atBoundary = Self.undoIsAtBoundary(field.after)
                monitor.beginPredictionWordAfterConfirmedUndo(processID: focus.processID,
                    sourceLayoutID: receipt.sourceLayoutID,
                    atBoundary: atBoundary)
                undoHeldFocus = atBoundary ? nil : (field.focus, receipt.sourceLayoutID)
            } else {
                monitor.markConverted()
            }
            converter.armManualRedoAfterConfirmedAutomaticUndo(receipt)
            recentAutomaticEdit = nil
            confirmedAdaptiveUndo = (receipt.notice.id, receipt.editReplacement,
                receipt.editOriginal, receipt.focus)
            return .confirmed
        }
    }

    private static func undoIsAtBoundary(_ observation: NativeFieldObservation) -> Bool {
        guard observation.selectionLength == 0,
              let prefix = Range(NSRange(location: 0,
                  length: observation.caretUTF16Location), in: observation.text) else { return false }
        return observation.text[prefix].last?.isWhitespace == true
    }

    /// Compare changed tokens rather than the entire two-word editing suffix.
    /// A trailing space or an unchanged neighbour must not bypass saved exclusions.
    static func containsDeniedChange(original: String, replacement: String) -> Bool {
        let old = original.split(whereSeparator: \.isWhitespace)
        let new = replacement.split(whereSeparator: \.isWhitespace)
        guard old.count == new.count else { return true }
        for (before, after) in zip(old, new) where before != after {
            let beforeWord = String(before).trimmingCharacters(in: .punctuationCharacters)
            let afterWord = String(after).trimmingCharacters(in: .punctuationCharacters)
            if AutoSwitchPolicy.isDeniedWord(beforeWord, afterWord) { return true }
        }
        return false
    }
}
