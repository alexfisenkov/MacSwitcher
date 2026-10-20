import AppKit

/// The HID callback only submits immutable values. Dictionary loading/scoring runs
/// outside that callback; AX is consulted only for a concrete, still-current edit.
@MainActor
final class PredictionCoordinator {
    private let monitor: KeyboardMonitor
    private let converter: TextConverter
    private let engineTask: Task<PredictionEngine?, Never>
    private var debounce: DispatchWorkItem?
    private var evaluation: Task<Void, Never>?
    private var anchorSessionID: UInt64?
    private var anchorFocus: CombinedShiftFocus?
    private var caretAnchor: PredictionCaretAnchor?
    var onApplied: ((String) -> Void)?

    init(monitor: KeyboardMonitor, converter: TextConverter) {
        self.monitor = monitor
        self.converter = converter
        engineTask = Task.detached(priority: .utility) {
            guard let lexicon = try? PredictionLexicon.bundled() else { return nil }
            return PredictionEngine(lexicon: lexicon)
        }
    }

    func invalidate() {
        debounce?.cancel(); debounce = nil
        evaluation?.cancel(); evaluation = nil
    }

    func submit(_ snapshot: PredictionSnapshot) {
        invalidate()
        if anchorSessionID != snapshot.sessionID {
            anchorSessionID = snapshot.sessionID
            anchorFocus = nil
            caretAnchor = nil
            // Capture once per uninterrupted typing session, after the first key
            // is delivered. Unknown initial focus stays unavailable for this session.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.anchorSessionID == snapshot.sessionID,
                      self.monitor.predictionSessionID == snapshot.sessionID,
                      snapshot.isCurrent(processID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                          revision: self.monitor.inputRevision, generation: self.monitor.predictionGeneration),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID,
                      !AutoSwitchPolicy.secureInputActive else { return }
                guard let focus = CombinedShiftFocus.capture(processID: snapshot.processID),
                      let selection = focus.initialSelection, selection.length == 0,
                      snapshot.isCurrent(processID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                          revision: self.monitor.inputRevision, generation: self.monitor.predictionGeneration) else { return }
                self.anchorFocus = focus
                self.caretAnchor = PredictionCaretAnchor(caretUTF16Location: selection.location,
                    inputUTF16Offset: snapshot.cumulativeUTF16Offset)
            }
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluation = Task { [weak self] in await self?.evaluate(snapshot) }
        }
        debounce = work
        // The original key must reach the destination before AX suffix verification.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(snapshot.atBoundary ? 12 : 70), execute: work)
    }

    private func isCurrent(_ snapshot: PredictionSnapshot) -> Bool {
        if AutoSwitchPolicy.secureInputActive {
            monitor.resetPredictionContext()
            return false
        }
        return !Task.isCancelled && SettingsManager.shared.autoSwitchEnabled && SettingsManager.shared.autoConvert
            && !AutoSwitchPolicy.shouldDeferToRemoteClient
            && !AutoSwitchPolicy.isDeniedApp(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            && snapshot.sessionID == monitor.predictionSessionID
            && snapshot.isCurrent(processID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                revision: monitor.inputRevision, generation: monitor.predictionGeneration)
    }

    private func evaluate(_ snapshot: PredictionSnapshot) async {
        guard isCurrent(snapshot), let engine = await engineTask.value,
              isCurrent(snapshot),
              let source = LayoutSwitcher.installedLayouts().first(where: {
                  LayoutSwitcher.sourceID($0) == snapshot.sourceLayoutID
              }), let language = LayoutSwitcher.languageCode(source),
              let pair = LayoutSwitcher.combinedShiftContext(sourceLayoutID: snapshot.sourceLayoutID),
              let opposite = LayoutSwitcher.installedLayouts().first(where: {
                  LayoutSwitcher.sourceID($0) == pair.targetLayoutID
              }), let oppositeLanguage = LayoutSwitcher.languageCode(opposite),
              Set([String(language.prefix(2)), String(oppositeLanguage.prefix(2))]) == Set(["ru", "en"]) else { return }
        let characterMapping = DynamicKeyMapping.buildMap(from: source, to: opposite)
        guard !characterMapping.isEmpty else { return }
        let alwaysConvertWords = SettingsManager.shared.alwaysConvertWordsSet
        let proposal = await Task.detached(priority: .userInitiated) {
            engine.evaluate(suffix: snapshot.suffix, sourceLanguage: language,
                atBoundary: snapshot.atBoundary, precedingWords: snapshot.precedingWords,
                alwaysConvertWords: alwaysConvertWords, characterMapping: characterMapping)
        }.value
        guard isCurrent(snapshot), let proposal,
              proposal.originalSuffix == snapshot.suffix,
              !Self.containsDeniedChange(original: proposal.originalSuffix, replacement: proposal.replacementSuffix),
              let target = LayoutSwitcher.installedLayouts().first(where: {
                  [pair.sourceLayoutID, pair.targetLayoutID].contains(LayoutSwitcher.sourceID($0))
                      && LayoutSwitcher.languageCode($0)?.lowercased().hasPrefix(proposal.targetLanguage) == true
              }), let originalFocus = anchorFocus,
              PredictionFocusAnchorPolicy.permits(originalSession: anchorSessionID,
                  currentSession: snapshot.sessionID, capturedOriginalField: true,
                  sameField: originalFocus.isCurrent()),
              let caretAnchor, let currentSelection = originalFocus.selectionRange(),
              caretAnchor.permits(location: currentSelection.location, selectionLength: currentSelection.length,
                  cumulativeOffset: snapshot.cumulativeUTF16Offset),
              isCurrent(snapshot) else { return }
        // Retain the first session's field identity; only its current collapsed
        // caret is refreshed. A same-PID different field is never a new baseline.
        let focus = CombinedShiftFocus(processID: originalFocus.processID, element: originalFocus.element,
            initialSelection: currentSelection)
        guard let edit = PredictionSuffixEdit(original: proposal.originalSuffix,
            replacement: proposal.replacementSuffix) else { return }
        let resultID = LayoutSwitcher.sourceID(target)
        let execution = CombinedShiftExecutionContext(focus: focus, inputRevision: snapshot.inputRevision,
            currentInputRevision: { [weak monitor] in
                guard let monitor, monitor.predictionGeneration == snapshot.generation else { return UInt64.max }
                return monitor.inputRevision
            })
        guard converter.replaceVerifiedSuffix(original: edit.original,
            replacement: edit.replacement, sourceLayoutID: snapshot.sourceLayoutID,
            resultLayoutID: resultID, execution: execution) else { return }
        monitor.recordPredictionResult(original: proposal.originalSuffix,
            replacement: proposal.replacementSuffix, resultLayoutID: resultID)
        if LayoutSwitcher.currentLayoutID() != resultID { LayoutSwitcher.switchTo(layoutID: resultID) }
        let changedWord = zip(proposal.originalSuffix.split(whereSeparator: \.isWhitespace),
                              proposal.replacementSuffix.split(whereSeparator: \.isWhitespace))
            .first(where: { $0 != $1 }).map { String($0.0) } ?? edit.original
        onApplied?(changedWord)
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
