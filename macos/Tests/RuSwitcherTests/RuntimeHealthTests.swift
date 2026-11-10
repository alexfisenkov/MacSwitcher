import XCTest
@testable import RuSwitcher

@MainActor
final class RuntimeHealthTests: XCTestCase {
    private func snapshot(master: Bool = true, permissions: Bool = true,
                          secure: Bool = false, sleeping: Bool = false,
                          tapHealthy: Bool = true, lease: Bool = false,
                          shellEdit: Bool = false, unknown: Bool = false,
                          shell: RuntimeHealthSnapshot.Shell = .disabled) -> RuntimeHealthSnapshot {
        RuntimeHealthSnapshot(monitoring: true, masterEnabled: master,
            accessibilityGranted: permissions, inputMonitoringGranted: permissions,
            secureInput: secure, sleeping: sleeping,
            tap: NativeTapRecoveryStatus(tapPresent: tapHealthy, tapEnabled: tapHealthy,
                fenceAvailable: tapHealthy), nativeLeaseActive: lease,
            shellEditActive: shellEdit, unknownEditRetained: unknown, shell: shell)
    }

    func testIdleReadyAndExpectedListenOnlyAreHealthy() {
        var observed = snapshot()
        var repairs = 0
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 0)
        observed = RuntimeHealthSnapshot(monitoring: true, masterEnabled: true,
            accessibilityGranted: true, inputMonitoringGranted: true,
            secureInput: false, sleeping: false,
            tap: NativeTapRecoveryStatus(tapPresent: true, tapEnabled: true,
                fenceAvailable: false, fenceRequired: false),
            nativeLeaseActive: false, shellEditActive: false,
            unknownEditRetained: false, shell: .disabled)
        XCTAssertEqual(health.poll(), .connected)
    }

    func testSecureExitAndWakeCoalesceOneRepairAfterEdit() {
        var observed = snapshot()
        var invalidations = 0, repairs = 0
        let health = RuntimeHealthController(observe: { observed },
            invalidateContext: { invalidations += 1 }, rearmTap: { repairs += 1 },
            pollTap: { _ in }, maintainShell: {})
        XCTAssertEqual(health.poll(), .connected)
        observed = snapshot(secure: true)
        XCTAssertEqual(health.poll(), .secureInputPaused)
        observed = snapshot(sleeping: true)
        XCTAssertEqual(health.poll(reason: .sleep), .sleeping)
        observed = snapshot(lease: true)
        XCTAssertEqual(health.poll(reason: .wake), .editDeferred)
        XCTAssertFalse(health.mayReconfigureTap())
        observed = snapshot(shellEdit: true)
        XCTAssertEqual(health.poll(), .editDeferred)
        observed = snapshot()
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(repairs, 1)
    }

    func testPermissionsMasterAndScheduledGateNeverRepairBlockedState() {
        var observed = snapshot(master: false)
        var repairs = 0, polls = 0
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { repairs += 1 }, pollTap: { _ in polls += 1 }, maintainShell: {})
        XCTAssertEqual(health.poll(), .off)
        observed = snapshot(permissions: false, tapHealthy: false)
        XCTAssertEqual(health.poll(), .permissionsRequired)
        XCTAssertFalse(health.mayReconfigureTap())
        XCTAssertEqual(repairs, 0)
        XCTAssertEqual(polls, 0)
        observed = snapshot(tapHealthy: false)
        XCTAssertEqual(health.poll(), .tapUnavailable)
        XCTAssertEqual(repairs, 1)
        XCTAssertTrue(health.mayReconfigureTap())
    }

    func testManualFailureAndUnknownOriginalNeverClaimEditorSuccess() {
        let observed = snapshot(unknown: true)
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: {}, pollTap: { _ in }, maintainShell: {},
            selfCheck: { [.init(id: .gesture, passed: false)] })
        XCTAssertEqual(health.poll(), .selfCheckFailed)
        let report = health.runManualCheck()
        XCTAssertEqual(report.state, .selfCheckFailed)
        XCTAssertEqual(report.checks, [.init(id: .gesture, passed: false)])
        XCTAssertTrue(report.unknownEditRetained)
    }

    func testAutomaticInternalCheckRunsOnceAndManualCheckRunsAgain() {
        let observed = snapshot()
        var runs = 0
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: {}, pollTap: { _ in }, maintainShell: {},
            selfCheck: { runs += 1; return [.init(id: .gesture, passed: true)] })
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(health.runManualCheck().state, .connected)
        XCTAssertEqual(runs, 2)
    }

    func testObservedSecureResumeKeepsNewWordAndDoesNotRestartHealthyTap() throws {
        let observed = snapshot() // periodic observations remain non-secure
        var repairs = 0, transitions = 0, resumes = 0
        let monitor = KeyboardMonitor()
        var snapshots: [PredictionSnapshot] = []
        monitor.onPredictionInput = { snapshots.append($0) }
        let health = RuntimeHealthController(observe: { observed },
            invalidateContext: { monitor.invalidateRuntimeInputContext() },
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        monitor.onRuntimeNormalKeyboardActivity = { health.noteNormalKeyboardActivity() }
        monitor.onRuntimeSecureInputObserved = {
            transitions += 1
            health.noteSecureInputObserved()
        }
        monitor.onRuntimeSecureInputResumed = {
            resumes += 1
            health.noteSecureInputResumed()
        }
        XCTAssertEqual(health.poll(), .connected)
        let before = monitor.predictionGeneration
        monitor.noteRuntimeSecureInput(true)
        monitor.noteRuntimeSecureInput(true)
        monitor.noteRuntimeSecureInput(false, isKeyboardEvent: false) // closing mouse-up is not keyboard proof
        XCTAssertEqual(resumes, 0)
        monitor.noteRuntimeSecureInput(false)
        XCTAssertEqual(transitions, 1)
        XCTAssertEqual(resumes, 1)
        XCTAssertGreaterThan(monitor.predictionGeneration, before)
        monitor.recordPredictionText("g", processID: 123, sourceLayoutID: "synthetic.en")
        let postResumeSession = monitor.predictionSessionID
        XCTAssertEqual(try XCTUnwrap(snapshots.last).suffix, "g")
        XCTAssertEqual(health.poll(), .connected)
        monitor.recordPredictionText("h", processID: 123, sourceLayoutID: "synthetic.en")
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(try XCTUnwrap(snapshots.last).suffix, "gh")
        XCTAssertEqual(monitor.predictionSessionID, postResumeSession)
        XCTAssertEqual(repairs, 0)
    }

    func testMouseOnlySecureExitDoesNotAcknowledgeKeyboardRecovery() {
        let observed = snapshot()
        var repairs = 0, resumes = 0
        let monitor = KeyboardMonitor()
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        monitor.onRuntimeSecureInputObserved = { health.noteSecureInputObserved() }
        monitor.onRuntimeSecureInputResumed = {
            resumes += 1
            health.noteSecureInputResumed()
        }
        XCTAssertEqual(health.poll(), .connected)
        monitor.noteRuntimeSecureInput(true)
        monitor.noteRuntimeSecureInput(false, isKeyboardEvent: false)
        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 1)
    }

    func testPolledSecureExitWithoutResumedCallbackStillRearms() {
        var observed = snapshot()
        var repairs = 0
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        XCTAssertEqual(health.poll(), .connected)
        observed = snapshot(secure: true)
        XCTAssertEqual(health.poll(), .secureInputPaused)
        observed = snapshot()
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 1)
    }

    func testPolledSecureExitAcknowledgmentDoesNotResurrectPendingRepair() {
        var observed = snapshot()
        var repairs = 0
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        let monitor = KeyboardMonitor()
        monitor.onRuntimeSecureInputObserved = { health.noteSecureInputObserved() }
        monitor.onRuntimeSecureInputResumed = { health.noteSecureInputResumed() }
        XCTAssertEqual(health.poll(), .connected)
        observed = snapshot(secure: true)
        XCTAssertEqual(health.poll(), .secureInputPaused)
        monitor.noteRuntimeSecureInput(true)
        observed = snapshot()
        monitor.noteRuntimeSecureInput(false) // callback reset before ordinary key
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 0)
    }

    func testSecureAcknowledgmentKeepsWakeAndBrokenTapRecovery() {
        var observed = snapshot()
        var repairs = 0
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { repairs += 1; observed = self.snapshot() },
            pollTap: { _ in }, maintainShell: {})
        XCTAssertEqual(health.poll(), .connected)
        observed = snapshot(secure: true, sleeping: true)
        XCTAssertEqual(health.poll(reason: .sleep), .sleeping)
        observed = snapshot()
        health.noteSecureInputResumed()
        XCTAssertEqual(health.poll(reason: .wake), .connected)
        XCTAssertEqual(repairs, 1, "A secure acknowledgment must not cancel wake recovery")

        observed = snapshot(tapHealthy: false, lease: true)
        health.noteSecureInputObserved()
        health.noteSecureInputResumed() // unhealthy structure cannot acknowledge it
        XCTAssertFalse(health.noteNormalKeyboardActivity())
        XCTAssertEqual(health.poll(), .editDeferred)
        observed = snapshot(tapHealthy: false)
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 2, "Broken tap still repairs after the lease")
    }

    func testDeferredWakeDoesNotEraseWordProvenByFreshKeyboardCallback() throws {
        var observed = snapshot()
        let monitor = KeyboardMonitor()
        var snapshots: [PredictionSnapshot] = []
        var repairs = 0
        monitor.onPredictionInput = { snapshots.append($0) }
        let health = RuntimeHealthController(observe: { observed },
            invalidateContext: { monitor.invalidateRuntimeInputContext() },
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        monitor.onRuntimeNormalKeyboardActivity = { health.noteNormalKeyboardActivity() }
        XCTAssertEqual(health.poll(), .connected)
        monitor.recordPredictionText("old", processID: 123, sourceLayoutID: "synthetic.en")
        observed = snapshot(lease: true)
        XCTAssertEqual(health.poll(reason: .wake), .editDeferred)
        observed = snapshot()
        monitor.noteRuntimeSecureInput(false) // ordinary keyboard callback before its text is recorded
        monitor.recordPredictionText("g", processID: 123, sourceLayoutID: "synthetic.en")
        let newSession = monitor.predictionSessionID
        XCTAssertEqual(try XCTUnwrap(snapshots.last).suffix, "g")
        XCTAssertEqual(health.poll(), .connected)
        monitor.recordPredictionText("h", processID: 123, sourceLayoutID: "synthetic.en")
        XCTAssertEqual(try XCTUnwrap(snapshots.last).suffix, "gh")
        XCTAssertEqual(monitor.predictionSessionID, newSession)
        XCTAssertEqual(repairs, 0)
    }

    func testDeferredPermissionReturnDoesNotEraseNewWord() throws {
        var observed = snapshot()
        let monitor = KeyboardMonitor()
        var snapshots: [PredictionSnapshot] = []
        var repairs = 0
        monitor.onPredictionInput = { snapshots.append($0) }
        let health = RuntimeHealthController(observe: { observed },
            invalidateContext: { monitor.invalidateRuntimeInputContext() },
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        monitor.onRuntimeNormalKeyboardActivity = { health.noteNormalKeyboardActivity() }
        XCTAssertEqual(health.poll(), .connected)
        monitor.recordPredictionText("old", processID: 123, sourceLayoutID: "synthetic.en")
        observed = snapshot(permissions: false)
        XCTAssertEqual(health.poll(), .permissionsRequired)
        observed = snapshot(lease: true)
        XCTAssertEqual(health.poll(), .editDeferred)
        observed = snapshot()
        XCTAssertTrue(monitor.noteRuntimeSecureInput(false))
        monitor.recordPredictionText("g", processID: 123, sourceLayoutID: "synthetic.en")
        let newSession = monitor.predictionSessionID
        XCTAssertEqual(health.poll(), .connected)
        monitor.recordPredictionText("h", processID: 123, sourceLayoutID: "synthetic.en")
        XCTAssertEqual(try XCTUnwrap(snapshots.last).suffix, "gh")
        XCTAssertEqual(monitor.predictionSessionID, newSession)
        XCTAssertEqual(repairs, 0)
    }

    func testPermissionRestoredBeforeNextPollKeepsFirstNewWord() throws {
        var observed = snapshot(permissions: false)
        let monitor = KeyboardMonitor()
        var snapshots: [PredictionSnapshot] = []
        var repairs = 0
        monitor.onPredictionInput = { snapshots.append($0) }
        let health = RuntimeHealthController(observe: { observed },
            invalidateContext: { monitor.invalidateRuntimeInputContext() },
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        monitor.onRuntimeNormalKeyboardActivity = { health.noteNormalKeyboardActivity() }
        XCTAssertEqual(health.poll(), .permissionsRequired)
        observed = snapshot() // grant is back before the next two-second poll
        XCTAssertTrue(monitor.noteRuntimeSecureInput(false))
        monitor.recordPredictionText("g", processID: 123, sourceLayoutID: "synthetic.en")
        let session = monitor.predictionSessionID
        XCTAssertEqual(health.poll(), .connected)
        monitor.recordPredictionText("h", processID: 123, sourceLayoutID: "synthetic.en")
        XCTAssertEqual(try XCTUnwrap(snapshots.last).suffix, "gh")
        XCTAssertEqual(monitor.predictionSessionID, session)
        XCTAssertEqual(repairs, 0)
    }

    func testMasterEnabledBeforeNextPollKeepsFirstNewWord() throws {
        var observed = snapshot(master: false)
        let monitor = KeyboardMonitor()
        var snapshots: [PredictionSnapshot] = []
        var repairs = 0
        monitor.onPredictionInput = { snapshots.append($0) }
        let health = RuntimeHealthController(observe: { observed },
            invalidateContext: { monitor.invalidateRuntimeInputContext() },
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        monitor.onRuntimeNormalKeyboardActivity = { health.noteNormalKeyboardActivity() }
        XCTAssertEqual(health.poll(), .off)
        observed = snapshot() // master is enabled before the next two-second poll
        XCTAssertTrue(monitor.noteRuntimeSecureInput(false))
        monitor.recordPredictionText("g", processID: 123, sourceLayoutID: "synthetic.en")
        let session = monitor.predictionSessionID
        XCTAssertEqual(health.poll(), .connected)
        monitor.recordPredictionText("h", processID: 123, sourceLayoutID: "synthetic.en")
        XCTAssertEqual(try XCTUnwrap(snapshots.last).suffix, "gh")
        XCTAssertEqual(monitor.predictionSessionID, session)
        XCTAssertEqual(repairs, 0)
    }

    func testBlockedNormalKeyboardRevokesPendingShellAuthorization() {
        var observed = snapshot()
        let monitor = KeyboardMonitor()
        let gate = ShellAuthorizationGate()
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: {}, pollTap: { _ in }, maintainShell: {})
        monitor.onRuntimeNormalKeyboardActivity = { health.noteNormalKeyboardActivity() }
        monitor.onInputRevisionAdvanced = { _ = gate.next() }
        XCTAssertEqual(health.poll(), .connected)
        observed = snapshot(shellEdit: true)
        XCTAssertEqual(health.poll(reason: .wake), .editDeferred)
        let permitGeneration = gate.next()
        let previousRevision = monitor.inputRevision
        XCTAssertFalse(monitor.noteRuntimeSecureInput(false)) // forwarded, not buffered
        XCTAssertGreaterThan(monitor.inputRevision, previousRevision)
        XCTAssertFalse(gate.allows(permitGeneration))
    }

    func testKnownDeniedStateWaitsForReadyCallbackAndLaterDenialIsNewEpisode() {
        var observed = snapshot(permissions: false)
        let monitor = KeyboardMonitor()
        var repairs = 0, resets = 0
        let health = RuntimeHealthController(observe: { observed },
            invalidateContext: { resets += 1 }, rearmTap: { repairs += 1 },
            pollTap: { _ in }, maintainShell: {})
        monitor.onRuntimeNormalKeyboardActivity = { health.noteNormalKeyboardActivity() }
        XCTAssertEqual(health.poll(), .permissionsRequired)
        XCTAssertFalse(monitor.noteRuntimeSecureInput(false)) // no buffering while blocked
        XCTAssertEqual(resets, 0)
        observed = snapshot()
        XCTAssertTrue(monitor.noteRuntimeSecureInput(false))
        XCTAssertEqual(resets, 1) // stale context retired before the first new key
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 0)
        observed = snapshot(permissions: false)
        XCTAssertEqual(health.poll(), .permissionsRequired)
        observed = snapshot()
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 1) // new episode without a keyboard acknowledgment
    }

    func testReadyKeyboardHotPathDoesNotObserveHealthWithoutPendingRecovery() {
        var observations = 0
        let health = RuntimeHealthController(observe: {
            observations += 1
            return self.snapshot()
        }, invalidateContext: {}, rearmTap: {}, pollTap: { _ in }, maintainShell: {})
        XCTAssertTrue(health.noteNormalKeyboardActivity())
        XCTAssertTrue(health.noteNormalKeyboardActivity())
        XCTAssertEqual(observations, 0)
    }

    func testLaterWakeStillRepairsAfterEarlierKeyboardAcknowledgment() {
        var observed = snapshot()
        var repairs = 0
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        XCTAssertEqual(health.poll(), .connected)
        observed = snapshot(lease: true)
        XCTAssertEqual(health.poll(reason: .wake), .editDeferred)
        observed = snapshot()
        XCTAssertTrue(health.noteNormalKeyboardActivity())
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 0)
        XCTAssertEqual(health.poll(reason: .wake), .connected)
        XCTAssertEqual(repairs, 1)
        observed = snapshot(permissions: false)
        XCTAssertEqual(health.poll(), .permissionsRequired)
        observed = snapshot()
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 2, "A future permission restoration is not acknowledged early")
    }

    func testPolledSleepExitDoesNotReplayAfterKeyboardAcknowledgment() {
        var observed = snapshot()
        var repairs = 0
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        XCTAssertEqual(health.poll(), .connected)
        observed = snapshot(sleeping: true)
        XCTAssertEqual(health.poll(reason: .sleep), .sleeping)
        observed = snapshot()
        XCTAssertTrue(health.noteNormalKeyboardActivity())
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 0)
    }

    func testManualCheckOnlyRepairsStructuralFaultAndDefersActiveEdit() {
        var observed = snapshot()
        var repairs = 0
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { repairs += 1; observed = self.snapshot() },
            pollTap: { _ in }, maintainShell: {})
        XCTAssertEqual(health.runManualCheck().state, .connected)
        XCTAssertEqual(repairs, 0)
        observed = snapshot(tapHealthy: false, lease: true)
        XCTAssertEqual(health.runManualCheck().state, .editDeferred)
        XCTAssertEqual(repairs, 0)
        observed = snapshot(tapHealthy: false)
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(repairs, 1)
    }

    func testShellFaultIsDistinctFromNormalNoSession() {
        var observed = snapshot(shell: .listening(sessions: 0))
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: {}, pollTap: { _ in }, maintainShell: {})
        XCTAssertEqual(health.poll(), .connected)
        observed = snapshot(shell: .transientStartupFailure)
        XCTAssertEqual(health.poll(), .shellRecovering)
        observed = snapshot(shell: .needsUserAction)
        XCTAssertEqual(health.poll(), .shellNeedsUserAction)
    }

    func testFirstRunWithoutPermissionsReportsRequiredAction() {
        let observed = RuntimeHealthSnapshot(monitoring: false, masterEnabled: true,
            accessibilityGranted: false, inputMonitoringGranted: false,
            secureInput: false, sleeping: false,
            tap: NativeTapRecoveryStatus(tapPresent: false, tapEnabled: false,
                fenceAvailable: false), nativeLeaseActive: false,
            shellEditActive: false, unknownEditRetained: false, shell: .disabled)
        var repairs = 0
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { repairs += 1 }, pollTap: { _ in }, maintainShell: {})
        XCTAssertEqual(health.poll(), .permissionsRequired)
        XCTAssertEqual(repairs, 0)
    }

    func testRearmReadsFreshTapBeforePollingForAnotherRecovery() {
        var observed = snapshot(tapHealthy: false)
        var polledNeedsRecovery: [Bool] = []
        let health = RuntimeHealthController(observe: { observed }, invalidateContext: {},
            rearmTap: { observed = self.snapshot() },
            pollTap: { polledNeedsRecovery.append($0) }, maintainShell: {})
        XCTAssertEqual(health.poll(), .tapUnavailable)
        observed = snapshot(secure: true, tapHealthy: false)
        XCTAssertEqual(health.poll(), .secureInputPaused)
        observed = snapshot(tapHealthy: false)
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertEqual(polledNeedsRecovery.last, false)
    }
}
