import AppKit
import Foundation

struct ShellStartupRetryPolicy {
    enum Fault: Equatable { case transient, needsUserAction }
    private(set) var fault: Fault?
    private(set) var retryCount = 0
    private(set) var nextRetryAt: TimeInterval = 0

    mutating func failed(_ fault: Fault, now: TimeInterval) {
        self.fault = fault
        nextRetryAt = now + 30
    }
    mutating func succeeded() {
        fault = nil
        retryCount = 0
        nextRetryAt = 0
    }
    mutating func disabled() { succeeded() }
    mutating func claimRetry(now: TimeInterval, safe: Bool) -> Bool {
        guard fault == .transient, safe, retryCount < 3, now >= nextRetryAt else { return false }
        retryCount += 1
        nextRetryAt = now + 30
        return true
    }
}

/// Manual double-Shift bridge for a shell-owned editable line. No AX setter,
/// clipboard, synthetic key or command execution is used by this path.
@MainActor
final class ManualShellCoordinator {
    struct RecoveryOriginal {
        let id: UUID
        var text: String?
        let sessionPID: Int32
        let tty: String
        let lineNonce: String
        var archive: RecoveryArchive.Receipt?
    }

    private struct Pending {
        let hostPID: Int32
        let revision: UInt64
        let authorizationGeneration: UInt64
        let task: Task<PreparedSession?, Never>
    }

    private struct PreparedSession: Sendable {
        let handle: GenericShellPreparedHandle
        let anchor: ShellFocusAnchor
    }

    private struct Confirmed {
        let before: GenericShellEditorSnapshot
        let after: GenericShellEditorSnapshot
    }

    private var broker: GenericShellEditorBroker?
    let authorizationGate: ShellAuthorizationGate
    private var pending: Pending?
    private var lastConfirmed: Confirmed?
    private(set) var uncertainOriginals: [RecoveryOriginal] = []
    private var inFlightOriginals: [UUID: RecoveryOriginal] = [:]
    private var archiveInFlight = false
    private var requestedEnabled = false
    private var startupRetry = ShellStartupRetryPolicy()
    var onUnknown: (() -> Void)?
    var onConfirmed: ((String) -> Void)?

    var isEnabled: Bool { broker != nil }
    var isRequested: Bool { requestedEnabled }
    var hasUnbackedUnknown: Bool { uncertainOriginals.contains { $0.archive == nil && $0.text != nil } }
    var hasInFlightEdit: Bool { !inFlightOriginals.isEmpty }
    var hasPendingPreparation: Bool { pending != nil }
    var health: RuntimeHealthSnapshot.Shell {
        guard requestedEnabled else { return .disabled }
        if !uncertainOriginals.isEmpty && broker == nil { return .needsUserAction }
        if let broker { return .listening(sessions: broker.registeredSessions().count) }
        switch startupRetry.fault {
        case .transient:
            return startupRetry.retryCount < 3 ? .transientStartupFailure : .needsUserAction
        case .needsUserAction, .none: return .needsUserAction
        }
    }

    /// Off-input maintenance only. A healthy listener with zero prompts stays
    /// untouched; any uncertain original or in-flight path blocks restart.
    func maintainHealth(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let broker { broker.pruneClosedSessions(); return }
        let safe = requestedEnabled && pending == nil && inFlightOriginals.isEmpty
            && uncertainOriginals.isEmpty && !archiveInFlight
        guard startupRetry.claimRetry(now: now, safe: safe) else { return }
        startBroker(now: now)
    }

    func invalidatePendingForRuntimeTransition() {
        guard pending != nil, inFlightOriginals.isEmpty else { return }
        _ = authorizationGate.next()
        pending?.task.cancel()
        pending = nil
    }

    init(gate: ShellAuthorizationGate = ShellAuthorizationGate()) {
        authorizationGate = gate
    }

    @discardableResult
    func reserveInFlight(_ source: RecoveryOriginal, requestID: UUID) -> Bool {
        guard !uncertainOriginals.contains(where: {
                $0.sessionPID == source.sessionPID && $0.tty == source.tty
                    && $0.lineNonce == source.lineNonce
            }),
            uncertainOriginals.filter({ $0.archive == nil && $0.text != nil }).count
                + inFlightOriginals.count < 8,
            inFlightOriginals[requestID] == nil else { return false }
        inFlightOriginals[requestID] = source
        return true
    }

    func finishInFlight(requestID: UUID, uncertain: Bool) {
        guard let source = inFlightOriginals.removeValue(forKey: requestID) else { return }
        if uncertain {
            uncertainOriginals.append(source)
            onUnknown?()
        }
    }

    func configure(enabled: Bool) {
        requestedEnabled = enabled
        guard enabled else {
            _ = authorizationGate.next()
            pending?.task.cancel()
            pending = nil
            broker?.stop()
            broker = nil
            startupRetry.disabled()
            return
        }
        guard broker == nil else { return }
        startBroker(now: ProcessInfo.processInfo.systemUptime)
    }

    private func startBroker(now: TimeInterval) {
        do {
            let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let parent = cache.appendingPathComponent("MacSwitcher", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let directory = parent.appendingPathComponent("terminal-bridge", isDirectory: true)
            let discovery = SelectedTTYCapabilityDiscovery()
            let proof = ScriptableShellFocusProof(
                readerForPID: { pid in
                    guard let capability = discovery.capability(pid: pid) else { return nil }
                    return ScriptableSelectedTTYReader(capability: capability,
                        executor: NativeReadOnlyAppleEventExecutor())
                },
                frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
            let bridge = GenericShellEditorBroker(directory: directory, focusProof: proof)
            try bridge.start()
            broker = bridge
            startupRetry.succeeded()
        } catch {
            broker = nil // opt-in preference remains; no unsafe fallback transport
            let fault: ShellStartupRetryPolicy.Fault
            if let brokerError = error as? GenericShellEditorBroker.BrokerError,
               case .transientStartup = brokerError {
                fault = .transient
            } else {
                fault = .needsUserAction
            }
            startupRetry.failed(fault, now: now)
        }
    }

    /// First solo Shift already switched the input source. Preparation sends
    /// no command text to the app; zsh retains its own initial snapshot.
    func prepare(first request: CombinedShiftRequest) {
        let permitGeneration = authorizationGate.next()
        pending?.task.cancel()
        pending = nil
        guard let broker, let focus = request.focus,
              focus.initialSelection != nil else { return }
        let hostPID = request.frontProcessID
        let task = Task.detached(priority: .userInitiated) { () -> PreparedSession? in
            guard let anchor = ShellFocusAnchor.capture(focus, hostPID: hostPID) else { return nil }
            guard anchor.isCurrent(),
                  let handle = try? broker.prepareFocused(),
                  anchor.isCurrent() else { return nil }
            return PreparedSession(handle: handle, anchor: anchor)
        }
        pending = Pending(hostPID: request.frontProcessID,
            revision: request.inputRevision, authorizationGeneration: permitGeneration, task: task)
    }

    /// Returns true when it takes ownership of the second tap. A missing
    /// prepared shell target calls the ordinary native fallback unchanged.
    func convert(second request: CombinedShiftRequest, context: CombinedShiftContext,
                 converter: TextConverter, isCurrent: @escaping () -> Bool,
                 nativeFallback: @escaping () -> Void) -> Bool {
        guard let pending, let broker,
              pending.hostPID == request.frontProcessID,
              pending.revision == request.inputRevision else { return false }
        self.pending = nil
        Task { [weak self] in
            guard let self else { return }
            guard let prepared = await pending.task.value else {
                if self.authorizationGate.allows(pending.authorizationGeneration), isCurrent() {
                    nativeFallback()
                }
                return
            }
            let handle = prepared.handle, anchor = prepared.anchor
            guard self.authorizationGate.allows(pending.authorizationGeneration),
                  anchor.isCurrent(), isCurrent(),
                  let selection = request.focus?.initialSelection else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                try? broker.queryPrepared(handle)
            }.value
            guard self.authorizationGate.allows(pending.authorizationGeneration),
                  anchor.isCurrent(), isCurrent(),
                  let snapshot else { return }
            let external: GenericShellEditorPlanner.ExternalSelection = selection.length == 0
                ? .collapsed : .selected
            let mouseProof: TerminalMouseSelection.Proof?
            if case .selected = external, let focus = request.focus {
                mouseProof = TerminalMouseSelection.capture(focus: focus,
                    expectedBuffer: snapshot.buffer)
                guard mouseProof != nil else { return }
            } else {
                mouseProof = nil
            }
            guard let plan = self.makeProposal(snapshot: snapshot, request: request,
                context: context, converter: converter, externalSelection: external,
                mouseSelection: mouseProof?.scalarRange) else { return }
            guard self.authorizationGate.allows(pending.authorizationGeneration),
                  anchor.isCurrent(), mouseProof?.isCurrent() ?? true,
                  isCurrent() else { return }
            let gate = self.authorizationGate
            let permitGeneration = pending.authorizationGeneration
            let requiredSourceID = context.targetLayoutID
            let source = RecoveryOriginal(id: UUID(), text: snapshot.buffer,
                sessionPID: snapshot.sessionPID, tty: snapshot.tty,
                lineNonce: snapshot.lineNonce, archive: nil)
            guard self.reserveInFlight(source, requestID: plan.proposal.requestID) else { return }
            let outcome = await Task.detached(priority: .userInitiated) {
                broker.commit(plan.proposal, authorization: {
                    gate.permits(permitGeneration) {
                        anchor.isCurrent()
                        && (mouseProof?.isCurrent() ?? true)
                        && SettingsManager.shared.shellBridgeEnabled
                        && SettingsManager.shared.combinedShiftEnabled
                        && SettingsManager.shared.autoSwitchEnabled
                        && LayoutSwitcher.currentLayoutID() == requiredSourceID
                    }
                })
            }.value
            switch outcome {
            case .confirmed(let after):
                self.finishInFlight(requestID: plan.proposal.requestID, uncertain: false)
                self.recordConfirmed(before: snapshot, after: after)
                if isCurrent() { self.onConfirmed?(plan.resultLayoutID) }
            case .refused:
                self.finishInFlight(requestID: plan.proposal.requestID, uncertain: false)
                break
            case .uncertain:
                // Query state after lost ACK; never send a second edit packet.
                let current = await Task.detached(priority: .userInitiated) {
                    try? broker.query(sessionPID: handle.sessionPID, tty: handle.tty)
                }.value
                switch GenericShellEditorReconciliation.classify(before: snapshot,
                    proposal: plan.proposal, observed: current) {
                case .confirmed:
                    guard let current else { return }
                    self.finishInFlight(requestID: plan.proposal.requestID, uncertain: false)
                    self.recordConfirmed(before: snapshot, after: current)
                    if isCurrent() { self.onConfirmed?(plan.resultLayoutID) }
                case .unchanged:
                    self.finishInFlight(requestID: plan.proposal.requestID, uncertain: false)
                    break // no edit observed; stale or failed packet
                case .unknown:
                    self.finishInFlight(requestID: plan.proposal.requestID, uncertain: true)
                }
            }
        }
        return true
    }

    func recordConfirmed(before: GenericShellEditorSnapshot, after: GenericShellEditorSnapshot) {
        lastConfirmed = Confirmed(before: before, after: after)
    }

    func makeProposal(snapshot: GenericShellEditorSnapshot, request: CombinedShiftRequest,
                              context: CombinedShiftContext, converter: TextConverter,
                              externalSelection: GenericShellEditorPlanner.ExternalSelection,
                              convertWholeLine: Bool = SettingsManager.shared.convertWholeLine,
                              mouseSelection: Range<Int>? = nil)
        -> (proposal: GenericShellEditorProposal, resultLayoutID: String)? {
        if case .selected = externalSelection {
            guard let mouseSelection,
                  mouseSelection.lowerBound >= 0,
                  mouseSelection.upperBound <= snapshot.buffer.unicodeScalars.count,
                  mouseSelection.lowerBound < mouseSelection.upperBound else { return nil }
            let text = Self.scalarSlice(snapshot.buffer, mouseSelection)
            guard let result = converter.shellSelectionConversion(text, context: context),
                  let proposal = GenericShellEditorPlanner.proposal(snapshot: snapshot,
                      range: mouseSelection, replacement: result.replacement,
                      collapseToReplacementEnd: true) else { return nil }
            return (proposal, result.resultLayoutID)
        }
        guard case .collapsed = externalSelection else { return nil }
        if request.reconvert {
            if let last = lastConfirmed,
               last.after.sessionPID == snapshot.sessionPID,
               last.after.tty == snapshot.tty,
               last.after.lineNonce == snapshot.lineNonce,
               last.after.buffer == snapshot.buffer,
               last.after.cursor == snapshot.cursor,
               last.after.mark == snapshot.mark,
               last.after.regionActive == snapshot.regionActive {
                return (GenericShellEditorProposal(expected: snapshot,
                    replacementBuffer: last.before.buffer, replacementCursor: last.before.cursor,
                    requestID: UUID()), context.targetLayoutID)
            }
        }
        if let selection = GenericShellEditorPlanner.selectedRange(snapshot,
            externalSelection: externalSelection) {
            let text = Self.scalarSlice(snapshot.buffer, selection)
            guard let result = converter.shellSelectionConversion(text, context: context),
                  let proposal = GenericShellEditorPlanner.proposal(snapshot: snapshot,
                      range: selection, replacement: result.replacement) else { return nil }
            return (proposal, result.resultLayoutID)
        }
        guard case .collapsed = externalSelection, snapshot.regionActive == 0 else { return nil }
        if convertWholeLine,
           let range = GenericShellEditorPlanner.wholePrefixRange(snapshot,
                externalSelection: externalSelection) {
            let text = Self.scalarSlice(snapshot.buffer, range)
            guard let result = converter.shellSelectionConversion(text, context: context),
                  let proposal = GenericShellEditorPlanner.proposal(snapshot: snapshot,
                      range: range, replacement: result.replacement) else { return nil }
            return (proposal, result.resultLayoutID)
        }
        let wordKeys = request.wordKeys.isEmpty ? request.prevWordKeys : request.wordKeys
        let spaces = request.wordKeys.isEmpty ? request.boundaryCount : 0
        if !wordKeys.isEmpty,
           let wordContext = request.wordContext,
           let pair = DynamicKeyMapping.convertKeys(wordKeys, context: wordContext),
           let range = GenericShellEditorPlanner.exactWordRange(snapshot,
                word: pair.original, trailingSpaces: spaces, externalSelection: externalSelection) {
            guard let proposal = GenericShellEditorPlanner.proposal(snapshot: snapshot,
                range: range, replacement: pair.converted) else { return nil }
            return (proposal, DynamicKeyMapping.resultContext(for: pair.converted,
                requested: wordContext).targetLayoutID)
        }
        if wordKeys.isEmpty, let wordContext = request.wordContext,
           let range = GenericShellEditorPlanner.observedLastWordRange(snapshot,
                externalSelection: externalSelection) {
            let original = Self.scalarSlice(snapshot.buffer, range)
            guard let result = converter.shellSelectionConversion(original, context: wordContext),
                  let proposal = GenericShellEditorPlanner.proposal(snapshot: snapshot,
                      range: range, replacement: result.replacement) else { return nil }
            return (proposal, result.resultLayoutID)
        }
        return nil // no count-based deletion or inferred stale buffer fallback
    }

    private static func scalarSlice(_ text: String, _ range: Range<Int>) -> String {
        let scalars = Array(text.unicodeScalars)
        return String(String.UnicodeScalarView(scalars[range]))
    }

    /// Existing RecoveryArchive handles verified local persistence. This method
    /// is called only from explicit recovery/quit UI or approved auto-archive.
    func saveUncertainOriginals(in directory: URL) throws {
        guard !archiveInFlight else { throw RecoveryArchive.Failure.writeFailed }
        let originals = uncertainOriginals.filter { $0.archive == nil && $0.text != nil }
        guard !originals.isEmpty else { return }
        let receipt = try RecoveryArchive.saveVerified(originals.map {
            RecoveryArchive.Source(id: $0.id, text: $0.text!)
        }, in: directory)
        for index in uncertainOriginals.indices where uncertainOriginals[index].archive == nil {
            let source = uncertainOriginals[index]
            guard let text = source.text,
                  try RecoveryArchive.original(id: source.id, receipt: receipt) == text else {
                throw RecoveryArchive.Failure.verificationFailed
            }
            uncertainOriginals[index].archive = receipt
            uncertainOriginals[index].text = nil // verified durable backing releases RAM content
        }
        onUnknown?()
    }

    func scheduleAutomaticArchive(in directory: URL, onFailure: @escaping () -> Void) {
        guard !archiveInFlight else { return }
        let sources = uncertainOriginals.compactMap { original -> RecoveryArchive.Source? in
            guard original.archive == nil, let text = original.text else { return nil }
            return RecoveryArchive.Source(id: original.id, text: text)
        }
        guard !sources.isEmpty else { return }
        archiveInFlight = true
        Task { [weak self] in
            let receipt = await Task.detached(priority: .utility) { () -> RecoveryArchive.Receipt? in
                guard let receipt = try? RecoveryArchive.saveVerified(sources, in: directory) else { return nil }
                for source in sources {
                    guard (try? RecoveryArchive.original(id: source.id, receipt: receipt)) == source.text else {
                        return nil
                    }
                }
                return receipt
            }.value
            guard let self else { return }
            self.archiveInFlight = false
            guard let receipt else { onFailure(); return }
            let ids = Set(sources.map(\.id))
            for index in self.uncertainOriginals.indices where ids.contains(self.uncertainOriginals[index].id) {
                self.uncertainOriginals[index].archive = receipt
                self.uncertainOriginals[index].text = nil
            }
            self.onUnknown?()
        }
    }

}
