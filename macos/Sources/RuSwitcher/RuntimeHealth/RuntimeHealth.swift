import Foundation

/// Only structural observations. No field contents, key events, process IDs or TTYs.
struct RuntimeHealthSnapshot {
    enum Shell: Equatable {
        case disabled
        case listening(sessions: Int)
        case transientStartupFailure
        case needsUserAction
    }

    let monitoring: Bool
    let masterEnabled: Bool
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let secureInput: Bool
    let sleeping: Bool
    let tap: NativeTapRecoveryStatus
    let nativeLeaseActive: Bool
    let shellEditActive: Bool
    let unknownEditRetained: Bool
    let shell: Shell

    var permissionsGranted: Bool { accessibilityGranted && inputMonitoringGranted }
    var editActive: Bool { nativeLeaseActive || shellEditActive }
}

enum RuntimeHealthState: Equatable {
    case off, sleeping, permissionsRequired, secureInputPaused, editDeferred
    case tapUnavailable, shellRecovering, shellNeedsUserAction, unconfirmedEdit
    case connected, selfCheckFailed
}

struct RuntimeHealthReport {
    let state: RuntimeHealthState
    let checks: [RuntimeSelfCheck.Result]
    let shell: RuntimeHealthSnapshot.Shell
    let unknownEditRetained: Bool
}

/// Runs only on the existing icon refresh poll. Re-arming is coalesced across
/// Secure Input, wake and restored permissions and delayed past every edit gate.
@MainActor
final class RuntimeHealthController {
    enum Reason { case tick, sleep, wake, manual }

    private let observe: () -> RuntimeHealthSnapshot
    private let invalidateContext: () -> Void
    private let rearmTap: () -> Void
    private let pollTap: (Bool) -> Void
    private let maintainShell: () -> Void
    private let selfCheck: () -> [RuntimeSelfCheck.Result]
    private var previous: RuntimeHealthSnapshot?
    private var secureRearmPending = false
    private var wakeRearmPending = false
    private var permissionResumePending = false
    private var masterResumePending = false
    private var manualFaultRearmPending = false
    private var secureResumeAcknowledged = false
    private var wakeResumeAcknowledged = false
    private var permissionResumeAcknowledged = false
    private var masterResumeAcknowledged = false
    private var proactiveRearmPending: Bool {
        secureRearmPending || wakeRearmPending || permissionResumePending || masterResumePending
    }
    private var rearmPending: Bool { proactiveRearmPending || manualFaultRearmPending }
    private var selfCheckFailed = false
    private var didRunSelfCheck = false
    private(set) var state: RuntimeHealthState = .off

    init(observe: @escaping () -> RuntimeHealthSnapshot,
         invalidateContext: @escaping () -> Void,
         rearmTap: @escaping () -> Void,
         pollTap: @escaping (Bool) -> Void,
         maintainShell: @escaping () -> Void,
         selfCheck: @escaping () -> [RuntimeSelfCheck.Result] = { RuntimeSelfCheck.run() }) {
        self.observe = observe
        self.invalidateContext = invalidateContext
        self.rearmTap = rearmTap
        self.pollTap = pollTap
        self.maintainShell = maintainShell
        self.selfCheck = selfCheck
    }

    /// The scheduled retry also calls this gate immediately before a restart.
    func mayReconfigureTap() -> Bool {
        let current = observe()
        return current.monitoring && current.masterEnabled && current.permissionsGranted
            && !current.secureInput && !current.sleeping && !current.editActive
    }

    /// A protected callback can observe an interval missed by the timer.
    func noteSecureInputObserved() {
        secureRearmPending = true
        secureResumeAcknowledged = false
    }

    /// The first ordinary callback has already cleared stale context before
    /// recording its key. It proves a healthy tap is delivering again, so a
    /// later poll must not restart that tap and discard the new word.
    func noteSecureInputResumed() {
        let current = observe()
        guard current.monitoring, !current.secureInput, !current.tap.needsRecovery else { return }
        secureRearmPending = false
        secureResumeAcknowledged = true
    }

    /// Called only at the ordinary keyboard callback boundary, before its
    /// character enters the prediction window. No observation is made on the
    /// common path without an already observed lifecycle recovery reason.
    func noteNormalKeyboardActivity() -> Bool {
        guard proactiveRearmPending else { return true }
        let current = observe()
        guard current.monitoring && current.masterEnabled && current.permissionsGranted,
              !current.secureInput && !current.sleeping && !current.editActive,
              !current.tap.needsRecovery else { return false }
        // A polled pause may have delivered no protected callback. Clear its
        // old context now, before this first new key, without restarting a
        // demonstrably live tap after the key was recorded.
        invalidateContext()
        if secureRearmPending { secureResumeAcknowledged = true }
        if wakeRearmPending { wakeResumeAcknowledged = true }
        if permissionResumePending { permissionResumeAcknowledged = true }
        if masterResumePending { masterResumeAcknowledged = true }
        secureRearmPending = false
        wakeRearmPending = false
        permissionResumePending = false
        masterResumePending = false
        return true
    }

    @discardableResult
    func poll(reason: Reason = .tick) -> RuntimeHealthState {
        let current = observe()
        let wasPolledSecure = previous?.secureInput == true
        if current.secureInput {
            secureRearmPending = true
            secureResumeAcknowledged = false
        } else if wasPolledSecure && !secureResumeAcknowledged {
            secureRearmPending = true
        }
        if wasPolledSecure && !current.secureInput { secureResumeAcknowledged = false }
        if reason == .sleep || reason == .wake || current.sleeping {
            wakeRearmPending = true
            wakeResumeAcknowledged = false
        } else if previous?.sleeping == true && !wakeResumeAcknowledged {
            wakeRearmPending = true
        }
        if previous?.sleeping == true && !current.sleeping { wakeResumeAcknowledged = false }
        if !current.permissionsGranted {
            permissionResumePending = true
            permissionResumeAcknowledged = false
        } else if previous?.permissionsGranted == false && !permissionResumeAcknowledged {
            permissionResumePending = true
        }
        if previous?.permissionsGranted == false && current.permissionsGranted {
            permissionResumeAcknowledged = false
        }
        if !current.masterEnabled {
            masterResumePending = true
            masterResumeAcknowledged = false
        } else if previous?.masterEnabled == false && !masterResumeAcknowledged {
            masterResumePending = true
        }
        if previous?.masterEnabled == false && current.masterEnabled {
            masterResumeAcknowledged = false
        }
        if reason == .manual && current.tap.needsRecovery { manualFaultRearmPending = true }
        previous = current

        guard current.masterEnabled else { state = .off; return state }
        guard !current.sleeping else { state = .sleeping; return state }
        guard current.permissionsGranted else { state = .permissionsRequired; return state }
        guard !current.secureInput else { state = .secureInputPaused; return state }
        guard current.monitoring else { state = .tapUnavailable; return state }
        if !didRunSelfCheck {
            selfCheckFailed = selfCheck().contains { !$0.passed }
            didRunSelfCheck = true
        }
        guard !current.editActive else {
            state = (rearmPending || current.tap.needsRecovery) ? .editDeferred : classify(current)
            return state
        }

        if rearmPending {
            invalidateContext()
            secureRearmPending = false
            wakeRearmPending = false
            permissionResumePending = false
            masterResumePending = false
            manualFaultRearmPending = false
            rearmTap()
        }
        pollTap(observe().tap.needsRecovery)
        maintainShell()
        state = classify(observe())
        return state
    }

    func runManualCheck() -> RuntimeHealthReport {
        let results = selfCheck()
        selfCheckFailed = results.contains { !$0.passed }
        didRunSelfCheck = true
        let current = poll(reason: .manual)
        let latest = observe()
        return RuntimeHealthReport(state: current, checks: results, shell: latest.shell,
            unknownEditRetained: latest.unknownEditRetained)
    }

    private func classify(_ snapshot: RuntimeHealthSnapshot) -> RuntimeHealthState {
        if !snapshot.masterEnabled { return .off }
        if snapshot.sleeping { return .sleeping }
        if !snapshot.permissionsGranted { return .permissionsRequired }
        if snapshot.secureInput { return .secureInputPaused }
        if !snapshot.monitoring { return .tapUnavailable }
        if selfCheckFailed { return .selfCheckFailed }
        if snapshot.unknownEditRetained { return .unconfirmedEdit }
        if snapshot.tap.needsRecovery { return .tapUnavailable }
        switch snapshot.shell {
        case .needsUserAction: return .shellNeedsUserAction
        case .transientStartupFailure: return .shellRecovering
        case .disabled, .listening: return .connected
        }
    }
}
