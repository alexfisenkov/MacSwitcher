import AppKit
import ApplicationServices
import XCTest
@testable import RuSwitcher

/// Raises the synthetic session-wide Secure Input flag for one test and
/// returns the restore action. `holder` is the flag holder's PID.
func raiseSyntheticSecureFlag(holder: Int32? = 77) -> () -> Void {
    let flag = AutoSwitchPolicy.secureInputProbe
    let holderProbe = AutoSwitchPolicy.secureInputHolderProbe
    AutoSwitchPolicy.secureInputProbe = { true }
    AutoSwitchPolicy.secureInputHolderProbe = { holder }
    return {
        AutoSwitchPolicy.secureInputProbe = flag
        AutoSwitchPolicy.secureInputHolderProbe = holderProbe
    }
}

final class SecureFieldPolicyTests: XCTestCase {
    func testOnlyAPositivelyOrdinaryFieldMayBeUsedUnderTheFlag() {
        XCTAssertTrue(SecureFieldPolicy.mayUse(focus: .ordinary, flagRaised: true))
        XCTAssertFalse(SecureFieldPolicy.mayUse(focus: .secure, flagRaised: true))
        XCTAssertFalse(SecureFieldPolicy.mayUse(focus: .unknown, flagRaised: true))
        XCTAssertFalse(SecureFieldPolicy.mayUse(focus: nil, flagRaised: true), "flag and no answer = refuse")
        // Without the flag nothing is asked on the hot path; a known secure field still refuses.
        XCTAssertTrue(SecureFieldPolicy.mayUse(focus: nil, flagRaised: false))
        XCTAssertTrue(SecureFieldPolicy.mayUse(focus: .ordinary, flagRaised: false))
        XCTAssertFalse(SecureFieldPolicy.mayUse(focus: .secure, flagRaised: false))
        XCTAssertFalse(SecureFieldPolicy.mayUse(focus: .unknown, flagRaised: false))
    }

    func testSubroleAnswersAreClassifiedFailClosed() {
        XCTAssertEqual(SecureFieldPolicy.verdict(subroleStatus: .success,
            subrole: kAXSecureTextFieldSubrole as NSString), .secure)
        XCTAssertEqual(SecureFieldPolicy.verdict(subroleStatus: .success,
            subrole: "AXSearchField" as NSString), .ordinary)
        XCTAssertEqual(SecureFieldPolicy.verdict(subroleStatus: .attributeUnsupported, subrole: nil), .ordinary)
        XCTAssertEqual(SecureFieldPolicy.verdict(subroleStatus: .noValue, subrole: nil), .ordinary)
        XCTAssertEqual(SecureFieldPolicy.verdict(subroleStatus: .success, subrole: NSNumber(value: 1)), .unknown)
        XCTAssertEqual(SecureFieldPolicy.verdict(subroleStatus: .success, subrole: nil), .unknown)
        for status in [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .failure, .notImplemented] {
            XCTAssertEqual(SecureFieldPolicy.verdict(subroleStatus: status, subrole: nil), .unknown)
        }
    }

    func testFlagHolderOwnFieldAndUnknownHolderAreNeverOrdinary() {
        XCTAssertEqual(SecureFieldPolicy.flaggedVerdict(.ordinary, fieldProcessID: 501, holderProcessID: 77), .ordinary)
        XCTAssertEqual(SecureFieldPolicy.flaggedVerdict(.ordinary, fieldProcessID: 501, holderProcessID: 501), .secure)
        XCTAssertEqual(SecureFieldPolicy.flaggedVerdict(.ordinary, fieldProcessID: 501, holderProcessID: nil), .unknown)
        XCTAssertEqual(SecureFieldPolicy.flaggedVerdict(.ordinary, fieldProcessID: 0, holderProcessID: 77), .unknown)
        XCTAssertEqual(SecureFieldPolicy.flaggedVerdict(.secure, fieldProcessID: 501, holderProcessID: 77), .secure)
        XCTAssertEqual(SecureFieldPolicy.flaggedVerdict(.unknown, fieldProcessID: 501, holderProcessID: 77), .unknown)
    }

    /// Review F1: the system-wide element's timeout is the whole process's AX
    /// timeout, so the probe sets timeouts only on the elements it found.
    func testFocusedFieldProbeNeverChangesTheSystemWideTimeout() {
        let system = AXUIElementCreateSystemWide()
        let app = AXUIElementCreateApplication(9_101), field = AXUIElementCreateApplication(9_102)
        var timeouts: [(AXUIElement, Float)] = []
        func access(holder: Int32?, appTimeout: AXError = .success) -> FocusedFieldAccess {
            FocusedFieldAccess(systemWide: { system },
                element: { parent, attribute in
                    if CFEqual(parent, system) {
                        return attribute == kAXFocusedApplicationAttribute as CFString ? app : nil
                    }
                    return CFEqual(parent, app) && attribute == kAXFocusedUIElementAttribute as CFString ? field : nil
                },
                setTimeout: { element, value in
                    timeouts.append((element, value))
                    return CFEqual(element, app) ? appTimeout : .success
                },
                processID: { CFEqual($0, field) || CFEqual($0, app) ? 501 : nil },
                verdict: { _ in .ordinary }, holderProcessID: { holder })
        }
        XCTAssertEqual(SecureFieldPolicy.liveFocusedFieldVerdict(timeout: 0.02, access: access(holder: 77)), .ordinary)
        XCTAssertTrue(timeouts.contains { CFEqual($0.0, field) && $0.1 == 0.02 }, "the found field is bounded")
        XCTAssertEqual(SecureFieldPolicy.liveFocusedFieldVerdict(access: access(holder: 501)), .secure)
        XCTAssertEqual(SecureFieldPolicy.liveFocusedFieldVerdict(access: access(holder: 77, appTimeout: .failure)), .unknown)
        XCTAssertFalse(timeouts.contains { CFEqual($0.0, system) }, "the system-wide element is never touched")
    }

    @MainActor
    func testFlagWithDeliveredKeysCodeIsRecordedOncePerGesture() {
        var events: [RuntimeDiagnosticEvent] = []
        let record: (RuntimeDiagnosticEvent) -> Void = { events.append($0) }
        // One double-Shift gesture: the first tap, then the second.
        XCTAssertEqual(SecureFlagGestureGate.evaluate(isDouble: false, targetProcessID: 501,
            deliveredProcessID: 501, flagRaised: true, holderProcessID: 77, record: record), .admitted)
        XCTAssertEqual(SecureFlagGestureGate.evaluate(isDouble: true, targetProcessID: 501,
            deliveredProcessID: 501, flagRaised: true, holderProcessID: 77, record: record), .admitted)
        XCTAssertEqual(events, [.secureFlagWithEvents])
        // A second gesture writes the code once more.
        _ = SecureFlagGestureGate.evaluate(isDouble: true, targetProcessID: 501,
            deliveredProcessID: 501, flagRaised: true, holderProcessID: 77, record: record)
        XCTAssertEqual(events, [.secureFlagWithEvents, .secureFlagWithEvents])
    }

    @MainActor
    func testGestureUnderFlagNeedsDeliveredKeysInTheTargetAndAnotherHolder() {
        var events: [RuntimeDiagnosticEvent] = []
        let record: (RuntimeDiagnosticEvent) -> Void = { events.append($0) }
        XCTAssertEqual(SecureFlagGestureGate.evaluate(isDouble: true, targetProcessID: 501,
            deliveredProcessID: nil, flagRaised: true, holderProcessID: 77, record: record), .refused,
            "Shift alone reaches the tap even under genuine Secure Input")
        XCTAssertEqual(SecureFlagGestureGate.evaluate(isDouble: true, targetProcessID: 501,
            deliveredProcessID: 502, flagRaised: true, holderProcessID: 77, record: record), .refused)
        XCTAssertEqual(SecureFlagGestureGate.evaluate(isDouble: true, targetProcessID: 501,
            deliveredProcessID: 501, flagRaised: true, holderProcessID: 501, record: record), .refused)
        XCTAssertEqual(SecureFlagGestureGate.evaluate(isDouble: true, targetProcessID: 501,
            deliveredProcessID: 501, flagRaised: true, holderProcessID: nil, record: record), .refused)
        XCTAssertEqual(SecureFlagGestureGate.evaluate(isDouble: true, targetProcessID: 501,
            deliveredProcessID: nil, flagRaised: false, holderProcessID: nil, record: record), .flagDown)
        XCTAssertEqual(events, [])
    }

    // MARK: - Keyboard monitor buffer under the flag

    private func typeWord(_ word: String, into monitor: KeyboardMonitor) throws {
        for character in word {
            let code = try XCTUnwrap(KeyMapping.keycodeToEN.first(where: { $0.value == character })?.key)
            monitor.handleKeyDown(keyCode: code, flags: [], renderedText: String(character),
                renderedSourceLayoutID: "synthetic.en")
        }
    }

    private func bufferedWordKeys(_ monitor: KeyboardMonitor) throws -> Int {
        let context = CombinedShiftContext(sourceLayoutID: "synthetic.en", targetLayoutID: "synthetic.ru")
        let request = try XCTUnwrap(monitor.snapshotCombinedShiftRequest(action: .switchLayout(context),
            frontProcessID: 501, focus: nil, contextForSource: { _ in context }))
        return request.wordKeys.count + request.lineKeys.count
    }

    @MainActor
    func testPasswordFieldUnderFlagKeepsNoBufferAndNoDelivery() throws {
        let restore = raiseSyntheticSecureFlag()
        defer { restore() }
        for verdict in [SecureFieldVerdict.secure, .unknown] {
            let monitor = KeyboardMonitor()
            var snapshots = 0
            monitor.onPredictionInput = { _ in snapshots += 1 }
            monitor.secureFieldProbe = { verdict }
            try typeWord("ghbd", into: monitor)
            XCTAssertEqual(try bufferedWordKeys(monitor), 0, "\(verdict)")
            XCTAssertEqual(snapshots, 0)
            XCTAssertNil(monitor.secureFlagDeliveryProcessID)
        }
    }

    @MainActor
    func testOrdinaryFieldUnderFlagBuffersAndProvesDelivery() throws {
        let restore = raiseSyntheticSecureFlag()
        defer { restore() }
        let monitor = KeyboardMonitor()
        monitor.secureFieldProbe = { .ordinary }
        try typeWord("ghbd", into: monitor)
        XCTAssertEqual(try bufferedWordKeys(monitor), 8)
        let front = try XCTUnwrap(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        XCTAssertEqual(monitor.secureFlagDeliveryProcessID, front)
        // A later key in a password field withdraws the proof and the open word.
        monitor.secureFieldProbe = { .secure }
        try typeWord("x", into: monitor)
        XCTAssertNil(monitor.secureFlagDeliveryProcessID)
        XCTAssertEqual(try bufferedWordKeys(monitor), 0)
    }

    @MainActor
    func testFlagDownNeverAsksTheField() throws {
        let monitor = KeyboardMonitor()
        var probes = 0
        monitor.secureFieldProbe = { probes += 1; return .secure }
        try typeWord("ghbd", into: monitor)
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(try bufferedWordKeys(monitor), 8)
        XCTAssertNil(monitor.secureFlagDeliveryProcessID)
    }

    @MainActor
    func testRaisedFlagStillBlocksTapReconfigurationWhileKeysFlow() {
        let snapshot = RuntimeHealthSnapshot(monitoring: true, masterEnabled: true,
            accessibilityGranted: true, inputMonitoringGranted: true,
            secureInput: false, sleeping: false,
            tap: NativeTapRecoveryStatus(tapPresent: true, tapEnabled: true, fenceAvailable: true),
            nativeLeaseActive: false, shellEditActive: false, unknownEditRetained: false,
            shell: .disabled, secureFlagRaised: true)
        let health = RuntimeHealthController(observe: { snapshot }, invalidateContext: {},
            rearmTap: {}, pollTap: { _ in }, maintainShell: {}, selfCheck: { [] })
        XCTAssertEqual(health.poll(), .connected)
        XCTAssertFalse(health.mayReconfigureTap())
    }

    // MARK: - Autocomplete suggestion shape

    func testSuggestionIsASelectedTailStartingAtTheCaret() {
        let field = NativeFieldObservation(text: "ghbdtnxy", caretUTF16Location: 6, selectionLength: 2)
        XCTAssertTrue(AutocompleteSuggestion.isSuggestion(field, selection: CFRange(location: 6, length: 2)))
        let middle = NativeFieldObservation(text: "ghbdtnxyz", caretUTF16Location: 6, selectionLength: 2)
        XCTAssertFalse(AutocompleteSuggestion.isSuggestion(middle, selection: CFRange(location: 6, length: 2)))
        XCTAssertFalse(AutocompleteSuggestion.isSuggestion(field, selection: CFRange(location: 5, length: 2)))
        let collapsed = NativeFieldObservation(text: "ghbdtn", caretUTF16Location: 6, selectionLength: 0)
        XCTAssertFalse(AutocompleteSuggestion.isSuggestion(collapsed, selection: CFRange(location: 6, length: 0)))
        let whole = NativeFieldObservation(text: "xy", caretUTF16Location: 0, selectionLength: 2)
        XCTAssertFalse(AutocompleteSuggestion.isSuggestion(whole, selection: CFRange(location: 0, length: 2)))
    }

    func testDismissalIsProvenOnlyWhenTheTextBeforeTheCaretIsUntouched() {
        let before = NativeFieldObservation(text: "ghbdtnxy", caretUTF16Location: 6, selectionLength: 2)
        XCTAssertEqual(AutocompleteSuggestion.verify(before: before,
            after: .init(text: "ghbdtn", caretUTF16Location: 6, selectionLength: 0), caret: 6), .dismissed)
        XCTAssertEqual(AutocompleteSuggestion.verify(before: before,
            after: .init(text: "ghbdtnxy", caretUTF16Location: 6, selectionLength: 0), caret: 6), .tailRetained)
        XCTAssertEqual(AutocompleteSuggestion.verify(before: before,
            after: .init(text: "ghbdtnxy", caretUTF16Location: 6, selectionLength: 2), caret: 6), .changed)
        XCTAssertEqual(AutocompleteSuggestion.verify(before: before,
            after: .init(text: "ghbdtx", caretUTF16Location: 6, selectionLength: 0), caret: 6), .changed)
        XCTAssertEqual(AutocompleteSuggestion.verify(before: before,
            after: .init(text: "ghbdtn", caretUTF16Location: 5, selectionLength: 0), caret: 6), .changed)
        XCTAssertEqual(AutocompleteSuggestion.verify(before: before, after: nil, caret: 6), .changed)
    }
}
