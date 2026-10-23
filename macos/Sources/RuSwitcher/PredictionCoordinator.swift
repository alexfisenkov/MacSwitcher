import AppKit

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
    private var debounce: DispatchWorkItem?
    private var evaluation: Task<Void, Never>?
    private var anchorSessionID: UInt64?
    private var anchorFocus: CombinedShiftFocus?
    private var pendingCaretAnchor: PredictionPendingCaretAnchor?
    private let correctionReceipts: ConfirmedCorrectionReceipts
    private let receiptNow: () -> UInt64
    private var oneShotSuppression: OneShotCorrectionSuppression?
    private struct RecentAutomaticEdit {
        let focus: CombinedShiftFocus
        let inputRevision: UInt64
        let sessionID: UInt64
        let sourceLayoutID: String
        let resultLayoutID: String
        let receiptID: UUID?
    }
    private var recentAutomaticEdit: RecentAutomaticEdit?
    /// AppDelegate supplies a saved choice. Legacy call sites default to off.
    var russianPriorityProvider: () -> Bool = { false }
    /// Exact displayed source phrase and language; storage belongs to the caller.
    var phraseExceptionLookup: (_ exactOriginal: String, _ sourceLanguage: String) -> Bool = { _, _ in false }
    var onCorrection: ((ConfirmedCorrectionNotice) -> Void)?
    /// T02 may present a nonactivating explicit exception offer after gesture undo.
    var onConfirmedAutomaticUndo: ((ConfirmedCorrectionNotice) -> Void)?
    var onApplied: ((String) -> Void)?
    var onUnconfirmedEdit: (() -> Void)?
    var onSourceFailure: ((String, LayoutSelectionCommit.Outcome?) -> Void)?

    init(monitor: KeyboardMonitor, converter: TextConverter,
         platform: PredictionCoordinatorPlatform? = nil, engine: PredictionEngine? = nil,
         receiptNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.monitor = monitor
        self.converter = converter
        self.platform = platform ?? .live(monitor: monitor)
        self.receiptNow = receiptNow
        self.correctionReceipts = ConfirmedCorrectionReceipts(now: receiptNow)
        if let engine {
            engineTask = Task { engine }
        } else {
            engineTask = Task.detached(priority: .utility) {
                guard let lexicon = try? PredictionLexicon.bundled() else {
                    RuntimeDiagnostics.record(.autoEngineUnavailable); return nil
                }
                RuntimeDiagnostics.record(.autoEngineReady)
                return PredictionEngine(lexicon: lexicon)
            }
        }
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
                    language: query.language) else { return nil }
                answer[query] = frequency > 0 || protectedWord(engine.lexicon,
                    query.word, query.language)
            }
            return answer
        }.value
    }

    func invalidate() {
        debounce?.cancel(); debounce = nil
        evaluation?.cancel(); evaluation = nil
    }

    func submit(_ snapshot: PredictionSnapshot) {
        invalidate()
        let bundleID = platform.frontmost().bundleID
        let route = platform.route(bundleID, snapshot.suffix, snapshot.sourceLayoutID)
        guard route != .blocked, !platform.deniedApp(bundleID) || route == .nativeCanary else {
            anchorSessionID = nil; anchorFocus = nil; pendingCaretAnchor = nil
            return // blocked editors must not incur a synchronous AX capture
        }
        if anchorSessionID != snapshot.sessionID {
            RuntimeDiagnostics.record(.autoAnchorSessionChanged)
            anchorSessionID = snapshot.sessionID
            anchorFocus = nil
            pendingCaretAnchor = nil
            captureOriginalAnchor(snapshot)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            RuntimeDiagnostics.record(.autoWorkStarted)
            self.evaluation = Task { [weak self] in await self?.evaluate(snapshot) }
        }
        debounce = work
        // The original key must reach the destination before AX suffix verification.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(snapshot.atBoundary ? 12 : 70), execute: work)
    }

    private func captureOriginalAnchor(_ snapshot: PredictionSnapshot) {
        // Capture before returning the first callback, rather than letting a later
        // queued capture become stale after a burst. Unknown focus stays unavailable;
        // a subsequent proposal must never establish a different field as baseline.
        guard snapshot.sessionID == monitor.predictionSessionID,
              snapshot.isCurrent(processID: platform.frontmost().processID,
                  revision: monitor.inputRevision, generation: monitor.predictionGeneration),
              !platform.isSecure() else {
            RuntimeDiagnostics.record(.autoAnchorStale); return
        }
        guard let focus = platform.captureFocus(snapshot.processID) else {
            RuntimeDiagnostics.record(.autoAnchorUnavailable); return
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

    private func retryRenderVerification(_ snapshot: PredictionSnapshot, attempt: Int) {
        // AX may briefly lag the event queue. Retry only this current snapshot and
        // original field; a new key, focus reset or explicit cancellation stops it.
        guard attempt < 3, isCurrent(snapshot) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluation = Task { [weak self] in await self?.evaluate(snapshot, renderAttempt: attempt + 1) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(15), execute: work)
    }

    private func isCurrent(_ snapshot: PredictionSnapshot) -> Bool {
        if platform.isSecure() {
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

    private func evaluate(_ snapshot: PredictionSnapshot, renderAttempt: Int = 0) async {
        guard isCurrent(snapshot) else { RuntimeDiagnostics.record(.autoEvaluationStale); return }
        guard let engine = await engineTask.value else { RuntimeDiagnostics.record(.autoEngineUnavailable); return }
        guard isCurrent(snapshot) else { RuntimeDiagnostics.record(.autoEvaluationStale); return }
        guard let source = LayoutSwitcher.installedLayouts().first(where: {
                  LayoutSwitcher.sourceID($0) == snapshot.sourceLayoutID
              }), let language = LayoutSwitcher.languageCode(source),
              let pair = LayoutSwitcher.combinedShiftContext(sourceLayoutID: snapshot.sourceLayoutID),
              let opposite = LayoutSwitcher.installedLayouts().first(where: {
                  LayoutSwitcher.sourceID($0) == pair.targetLayoutID
              }), let oppositeLanguage = LayoutSwitcher.languageCode(opposite),
              Set([String(language.prefix(2)), String(oppositeLanguage.prefix(2))]) == Set(["ru", "en"]) else {
            RuntimeDiagnostics.record(.autoMappingUnavailable); return
        }
        let characterMapping = DynamicKeyMapping.buildMap(from: source, to: opposite)
        guard !characterMapping.isEmpty else { RuntimeDiagnostics.record(.autoMappingUnavailable); return }
        let alwaysConvertWords = SettingsManager.shared.alwaysConvertWordsSet
        let russianPriority = russianPriorityProvider()
        let proposal = await Task.detached(priority: .userInitiated) {
            engine.evaluate(suffix: snapshot.suffix, sourceLanguage: language,
                atBoundary: snapshot.atBoundary, precedingWords: snapshot.precedingWords,
                alwaysConvertWords: alwaysConvertWords, characterMapping: characterMapping,
                russianPriority: russianPriority)
        }.value
        guard isCurrent(snapshot) else { RuntimeDiagnostics.record(.autoEvaluationStale); return }
        guard let proposal else { RuntimeDiagnostics.record(.autoNoProposal); return }
        RuntimeDiagnostics.record(.autoProposal)
        guard proposal.originalSuffix == snapshot.suffix,
              !Self.containsDeniedChange(original: proposal.originalSuffix, replacement: proposal.replacementSuffix),
              !phraseExceptionLookup(proposal.originalSuffix, String(language.lowercased().prefix(2))) else {
            RuntimeDiagnostics.record(.autoProposalRejected); return
        }
        guard let target = LayoutSwitcher.installedLayouts().first(where: {
                  [pair.sourceLayoutID, pair.targetLayoutID].contains(LayoutSwitcher.sourceID($0))
                      && LayoutSwitcher.languageCode($0)?.lowercased().hasPrefix(proposal.targetLanguage) == true
              }) else { RuntimeDiagnostics.record(.autoTargetUnavailable); return }
        guard let originalFocus = anchorFocus else { RuntimeDiagnostics.record(.autoFocusAnchorUnavailable); return }
        guard PredictionFocusAnchorPolicy.permits(originalSession: anchorSessionID,
                  currentSession: snapshot.sessionID, capturedOriginalField: true,
                  sameField: platform.focusIsCurrent(originalFocus)) else {
            pendingCaretAnchor = nil
            RuntimeDiagnostics.record(.autoFocusMismatch); return
        }
        if let oneShotSuppression {
            if DispatchTime.now().uptimeNanoseconds > oneShotSuppression.expiresAt {
                self.oneShotSuppression = nil
            } else if oneShotSuppression.matches(focus: originalFocus,
                sourceLayoutID: snapshot.sourceLayoutID,
                original: proposal.originalSuffix, replacement: proposal.replacementSuffix) {
                self.oneShotSuppression = nil
                RuntimeDiagnostics.record(.autoProposalRejected)
                return
            }
        }
        guard var pending = pendingCaretAnchor, let currentSelection = originalFocus.selectionRange() else {
            RuntimeDiagnostics.record(.autoCaretUnavailable); return
        }
        // Retain the first session's field identity; only its current collapsed
        // caret is refreshed. A same-PID different field is never a new baseline.
        let focus = CombinedShiftFocus(processID: originalFocus.processID, element: originalFocus.element,
            initialSelection: currentSelection, fieldBoundary: originalFocus.fieldBoundary)
        let suffixMatches = focus.hasOriginalSuffixBeforeCaret(snapshot.suffix)
        let resolved = pending.resolve(sessionID: snapshot.sessionID, location: currentSelection.location,
            selectionLength: currentSelection.length, cumulativeOffset: snapshot.cumulativeUTF16Offset,
            sameField: platform.focusIsCurrent(originalFocus), snapshotIsCurrent: isCurrent(snapshot), suffixMatches: suffixMatches)
        pendingCaretAnchor = pending
        guard resolved != nil else {
            RuntimeDiagnostics.record(.autoCaretMismatch)
            retryRenderVerification(snapshot, attempt: renderAttempt)
            return
        }
        guard isCurrent(snapshot) else { RuntimeDiagnostics.record(.autoEvaluationStale); return }
        // The converter must preserve an unknown edit in this exact AX field.
        // Refuse before opening another input lease or recording a source window;
        // a different field remains eligible for its own verified edit.
        guard !converter.hasUnconfirmedAXEdit(in: focus) else {
            RuntimeDiagnostics.record(.unconfirmedEditBlocked)
            RuntimeDiagnostics.record(.autoEditRefused)
            DispatchQueue.main.async { [weak self] in self?.onUnconfirmedEdit?() }
            return
        }
        guard let edit = PredictionSuffixEdit(original: proposal.originalSuffix,
            replacement: proposal.replacementSuffix) else { return }
        let resultID = LayoutSwitcher.sourceID(target)
        let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: snapshot.inputRevision,
            currentInputRevision: { [weak monitor] in
                guard let monitor, monitor.predictionGeneration == snapshot.generation else { return UInt64.max }
                return monitor.inputRevision
            })
        guard let lease = platform.beginLease(snapshot.processID) else {
            RuntimeDiagnostics.record(.nativeFenceUnavailable); return
        }
        var requestedAt: UInt64 = 0
        let sourceCommit = NativeQueuedSourceCommit(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.platform.leaseIsCurrent(lease)
                && monitor.inputRevision == snapshot.inputRevision
                && self.platform.frontmost().processID == snapshot.processID
                && !self.platform.isSecure()
        }, request: { target in
            requestedAt = self.platform.sourceRequestedAt()
            return self.platform.selectSource(target)
        }, onUnconfirmed: { target in
            self.platform.noteUnconfirmedSource(target, requestedAt)
        })
        defer { platform.finishLease(lease, sourceCommit.confirmedLayoutID) }
        var textWasQueued = false
        let textConfirmed = converter.withNativeInputBudget({ [weak self] in
            self?.platform.leaseRemaining(lease)
        }) {
            converter.withNativeTextQueuedHandler({ target in
                guard target == resultID else { return }
                textWasQueued = true
            }) {
                converter.replaceVerifiedSuffix(original: edit.original,
                    replacement: edit.replacement, sourceLayoutID: snapshot.sourceLayoutID,
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
                monitor.resetPredictionContext()
                RuntimeDiagnostics.record(.autoTextUnconfirmed)
            } else {
                RuntimeDiagnostics.record(.autoEditRefused)
            }
            return
        }
        RuntimeDiagnostics.record(.autoTextConfirmed)
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
                    sourceLanguage: String(language.lowercased().prefix(2)),
                    sourceLayoutID: snapshot.sourceLayoutID, resultLayoutID: resultID,
                    field: $0)
            }
            rememberAutomaticEdit(focus: focus, sourceLayoutID: snapshot.sourceLayoutID,
                resultLayoutID: resultID, receiptID: notice?.id)
            let outcome = sourceCommit.outcome
            DispatchQueue.main.async { [weak self] in
                self?.onSourceFailure?(resultID, outcome)
            }
            RuntimeDiagnostics.record(sourceCommit.outcome == .unconfirmed ? .autoSourceUnconfirmed : .autoSourceFailed)
            return
        }
        RuntimeDiagnostics.record(.autoSourceConfirmed)
        monitor.recordPredictionResult(original: proposal.originalSuffix,
            replacement: proposal.replacementSuffix, resultLayoutID: resultID)
        RuntimeDiagnostics.record(.autoEditPosted)
        let notice = wholeField.flatMap {
            retainReceipt(proposal: proposal, edit: edit, focus: focus,
               sourceLanguage: String(language.lowercased().prefix(2)),
               sourceLayoutID: snapshot.sourceLayoutID, resultLayoutID: resultID,
               field: $0)
        }
        rememberAutomaticEdit(focus: focus, sourceLayoutID: snapshot.sourceLayoutID,
            resultLayoutID: resultID, receiptID: notice?.id)
        if let notice {
            // Present feedback only after the input fence has been released.
            DispatchQueue.main.async { [weak self] in self?.onCorrection?(notice) }
        }
        let changedWord = zip(proposal.originalSuffix.split(whereSeparator: \.isWhitespace),
                              proposal.replacementSuffix.split(whereSeparator: \.isWhitespace))
            .first(where: { $0 != $1 }).map { String($0.0) } ?? edit.original
        onApplied?(changedWord)
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
              !platform.isSecure(), !platform.remoteDeferred(),
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
        oneShotSuppression = OneShotCorrectionSuppression(focus: receipt.focus,
            sourceLayoutID: receipt.sourceLayoutID,
            original: receipt.notice.original, replacement: receipt.notice.replacement,
            expiresAt: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        onConfirmedAutomaticUndo?(receipt.notice)
    }

    /// The ID is consumed before attempting a mutation. UI actions never select
    /// a remembered range or reuse current selection as a new target.
    func undoCorrection(id: UUID, completion: @escaping (CorrectionUndoResult) -> Void) {
        completion(performUndoCorrection(id: id))
    }

    private func performUndoCorrection(id: UUID) -> CorrectionUndoResult {
        guard let receipt = correctionReceipts.claim(id) else { return .refused }
        let focus = receipt.focus
        guard !platform.isSecure(), !platform.remoteDeferred(),
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
        let sourceCommit = NativeQueuedSourceCommit(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.platform.leaseIsCurrent(lease)
                && self.monitor.inputRevision == receipt.inputRevision
                && self.platform.frontmost().processID == focus.processID
                && !self.platform.isSecure()
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
            } else {
                monitor.markConverted()
            }
            converter.armManualRedoAfterConfirmedAutomaticUndo(receipt)
            recentAutomaticEdit = nil
            oneShotSuppression = OneShotCorrectionSuppression(focus: focus,
                sourceLayoutID: receipt.sourceLayoutID,
                original: receipt.notice.original, replacement: receipt.notice.replacement,
                expiresAt: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
            return .confirmed
        }
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
