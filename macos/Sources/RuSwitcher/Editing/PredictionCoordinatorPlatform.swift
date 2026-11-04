import AppKit
import ApplicationServices

/// Exceptional undo-continuation probe on the physical callback path. One AX
/// focused-element read, with no selection or field-value request and no retry.
@MainActor
enum FocusedFieldIdentityProbe {
    static func capture(processID: Int32,
                        setMessagingTimeout: (AXUIElement, Float) -> AXError = {
                            AXUIElementSetMessagingTimeout($0, $1)
                        },
                        copyAttribute: (AXUIElement, CFString) -> (AXError, AnyObject?) = { app, attribute in
                            var raw: AnyObject?
                            let result = AXUIElementCopyAttributeValue(app, attribute, &raw)
                            return (result, raw)
                        }) -> AXUIElement? {
        guard processID > 0 else { return nil }
        let app = AXUIElementCreateApplication(processID)
        guard setMessagingTimeout(app, 0.001) == .success else { return nil }
        let (result, raw) = copyAttribute(app, kAXFocusedUIElementAttribute as CFString)
        guard result == .success, let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return raw as! AXUIElement
    }
}

/// Narrow OS-facing dependencies of the existing prediction coordinator.
/// Tests replace only field identity, source selection and lease transport;
/// the debounce, proposal policy and TextConverter stay production code.
@MainActor
struct PredictionCoordinatorPlatform {
    let frontmost: () -> (bundleID: String?, processID: Int32?)
    let currentLayoutID: () -> String?
    let route: (String?, String, String) -> AutomaticEditorRoute
    let deniedApp: (String?) -> Bool
    let autoSwitchEnabled: () -> Bool
    let autoConvertEnabled: () -> Bool
    let remoteDeferred: () -> Bool
    let secureInputActive: () -> Bool
    let captureFocus: (Int32) -> CombinedShiftFocus?
    var focusedIdentity: ((Int32) -> AXUIElement?)? = nil
    let focusIsCurrent: (CombinedShiftFocus) -> Bool
    let beginLease: (Int32) -> InputEventFence.Lease?
    let leaseIsCurrent: (InputEventFence.Lease) -> Bool
    let leaseRemaining: (InputEventFence.Lease) -> TimeInterval?
    let finishLease: (InputEventFence.Lease, String?) -> Void
    let selectSource: (String) -> LayoutSelectionCommit.Outcome
    let sourceRequestedAt: () -> UInt64
    let noteUnconfirmedSource: (String, UInt64) -> Void

    func isSecure() -> Bool { AutoSwitchPolicy.secureInputActive || secureInputActive() }

    static func live(monitor: KeyboardMonitor) -> Self {
        Self(frontmost: {
                let app = NSWorkspace.shared.frontmostApplication
                return (app?.bundleIdentifier, app?.processIdentifier)
            }, currentLayoutID: { LayoutSwitcher.currentLayoutID() },
            route: { AutomaticEditorPolicy.route(bundleID: $0, suffix: $1, sourceID: $2) },
            deniedApp: { AutoSwitchPolicy.isDeniedApp($0) },
            autoSwitchEnabled: { SettingsManager.shared.autoSwitchEnabled },
            autoConvertEnabled: { SettingsManager.shared.autoConvert },
            remoteDeferred: { AutoSwitchPolicy.shouldDeferToRemoteClient },
            secureInputActive: { false },
            captureFocus: { CombinedShiftFocus.capture(processID: $0) },
            focusedIdentity: { FocusedFieldIdentityProbe.capture(processID: $0) },
            focusIsCurrent: { $0.isCurrent() },
            beginLease: { monitor.beginNativeInputTransaction(processID: $0) },
            leaseIsCurrent: { monitor.nativeInputTransactionIsCurrent($0) },
            leaseRemaining: { monitor.nativeInputTransactionRemainingDuration($0) },
            finishLease: { monitor.finishNativeInputTransaction($0, replayLayoutID: $1) },
            selectSource: { LayoutSwitcher.switchToWithConfirmation(layoutID: $0) },
            sourceRequestedAt: { DispatchTime.now().uptimeNanoseconds },
            noteUnconfirmedSource: { monitor.noteUnconfirmedInputSource($0, requestedAt: $1) })
    }
}
