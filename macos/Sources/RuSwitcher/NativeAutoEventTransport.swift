import ApplicationServices
import AppKit
import Foundation

/// Preallocated, marked, PID-only events. Construction never posts input.
/// No AX selection, clipboard, global event destination, or asynchronous job.
@MainActor
struct NativeAutoEventTransport {
    private let insertion: [CGEvent]
    private let removal: [CGEvent]

    init?(original: String, replacement: String) {
        guard !original.isEmpty, original.count == replacement.count,
              original.utf16.count == original.count, replacement.utf16.count == replacement.count,
              replacement.utf16.count <= NativeAutomaticTextEditor.maximumUnits,
              let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = kRuSwitcherEventMarker
        source.localEventsSuppressionInterval = 0
        func pair(_ code: CGKeyCode) -> [CGEvent]? {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return nil }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: kRuSwitcherEventMarker)
                event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            }
            return [down, up]
        }
        guard let unicode = pair(0) else { return nil }
        let units = Array(replacement.utf16)
        for event in unicode {
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            guard CombinedShiftUnicode.payloadMatches(event, expected: units) else { return nil }
        }
        var navigation: [CGEvent] = []
        for code in [CGKeyCode(123), 51, 124] { // Left, Backspace, Right
            for _ in 0..<original.count {
                guard let events = pair(code) else { return nil }
                navigation.append(contentsOf: events)
            }
        }
        insertion = unicode
        removal = navigation
    }

    func postInsertion(to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        post(insertion, to: processID, whileCurrent: whileCurrent)
    }

    func postRemoval(to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        post(removal, to: processID, whileCurrent: whileCurrent)
    }

    private func post(_ events: [CGEvent], to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        guard processID > 0 else { return false }
        for offset in stride(from: 0, to: events.count, by: 2) {
            guard whileCurrent() else { return false }
            events[offset].postToPid(processID)
            let mayContinue = whileCurrent()
            // A key already sent down must be released even if the barrier or
            // deadline changed; this releases the already-posted key-down.
            events[offset + 1].postToPid(processID)
            guard mayContinue else { return false }
        }
        return true // queued, never interpreted as delivery confirmation
    }
}

@MainActor
extension NativeAutoEventTransport {
    static func execute(original: String, replacement: String, start: Int,
                        execution: CombinedShiftExecutionContext,
                        inputBarrierIsActive: @escaping () -> Bool) -> NativeAutomaticTextEditResult {
        guard start == 0, let transport = NativeAutoEventTransport(original: original, replacement: replacement) else { return .refused }
        let deadline = ProcessInfo.processInfo.systemUptime + NativeAutomaticTextEditor.maximumDuration
        let focus = execution.focus
        AXUIElementSetMessagingTimeout(focus.element, 0.003)
        defer { AXUIElementSetMessagingTimeout(focus.element, 0.05) }
        func cheapGate() -> Bool {
            ProcessInfo.processInfo.systemUptime < deadline && inputBarrierIsActive()
                && execution.inputRevision == execution.currentInputRevision()
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID
                && !AutoSwitchPolicy.secureInputActive
        }
        func validateFocus() -> Bool {
            var wasUnavailable = false
            let valid = NativeFocusRevalidation.validate(until: deadline,
                now: { ProcessInfo.processInfo.systemUptime }, mayContinue: cheapGate,
                read: {
                    let failure = execution.validationFailure(timeout: 0.003)
                    switch failure {
                    case .focusUnavailable:
                        wasUnavailable = true
                        RuntimeDiagnostics.record(.nativeAutoFocusRetry)
                    case .focusChanged: RuntimeDiagnostics.record(.executionFocusChanged)
                    case .wrongProcess: RuntimeDiagnostics.record(.executionWrongProcess)
                    case .revisionChanged: RuntimeDiagnostics.record(.executionRevisionChanged)
                    case .secureInput: RuntimeDiagnostics.record(.executionSecureInput)
                    case nil: break
                    }
                    return failure
                }, pause: { seconds in usleep(useconds_t(max(0, seconds) * 1_000_000)) })
            if wasUnavailable {
                RuntimeDiagnostics.record(valid ? .nativeAutoFocusRecovered : .nativeAutoFocusRecheckFailed)
            }
            return valid
        }
        let access = NativeAutomaticTextAccess(
            isValid: validateFocus,
            inputBarrierIsActive: inputBarrierIsActive,
            observe: { length in
                guard cheapGate(), length > 0, length <= NativeAutomaticTextEditor.maximumUnits * 2,
                      let range = focus.selectionRange(),
                      let text = focus.text(in: CFRange(location: start, length: length), allowValueFallback: false) else { return nil }
                var raw: AnyObject?
                guard AXUIElementCopyAttributeValue(focus.element, kAXValueAttribute as CFString, &raw) == .success,
                      let whole = raw as? String, whole.utf16.count == length, whole == text else { return nil }
                return NativeAutomaticTextObservation(textFromOriginalStart: text,
                    caretUTF16Location: range.location, selectionLength: range.length)
            },
            insertReplacement: {
                let posted = transport.postInsertion(to: focus.processID, whileCurrent: cheapGate)
                if posted { RuntimeDiagnostics.record(.nativeAutoInsertPosted) }
                return posted
            },
            deleteOriginal: {
                let posted = transport.postRemoval(to: focus.processID, whileCurrent: cheapGate)
                if posted { RuntimeDiagnostics.record(.nativeAutoRemovalPosted) }
                return posted
            },
            pause: { seconds in usleep(useconds_t(max(0, seconds) * 1_000_000)) },
            now: { ProcessInfo.processInfo.systemUptime })
        return NativeAutomaticTextEditor.replace(original: original, replacement: replacement,
            originalStartUTF16: start, access: access)
    }
}
