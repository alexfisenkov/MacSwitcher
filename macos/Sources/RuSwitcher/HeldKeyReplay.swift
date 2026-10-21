import CoreGraphics
import Foundation

/// The OS still owns this held physical event. Only its printable payload is
/// regenerated after the transaction's source has been independently observed.
enum HeldKeyReplay {
    /// Even a source request that was not acknowledged within its budget may
    /// complete later. Decode each delayed event using the source observed now,
    /// and return that immutable identity with its payload to the monitor.
    static func refreshUsingObservedSource(_ event: CGEvent,
        observeSource: () -> String = LayoutSwitcher.currentLayoutID,
        translate: ((String, UInt16, Bool, Bool) -> Character?)? = nil) -> String? {
        let observed = observeSource()
        let decoder: ((UInt16, Bool, Bool) -> Character?)? = translate.map { translate in
            { translate(observed, $0, $1, $2) }
        }
        guard rewrite(event, confirmedLayoutID: observed, currentLayoutID: { observed },
            translate: decoder) else { return nil }
        return observed
    }

    @discardableResult
    static func rewrite(_ event: CGEvent, confirmedLayoutID: String,
                        currentLayoutID: () -> String = LayoutSwitcher.currentLayoutID,
                        translate: ((UInt16, Bool, Bool) -> Character?)? = nil) -> Bool {
        guard event.type == .keyDown, !confirmedLayoutID.isEmpty,
              currentLayoutID() == confirmedLayoutID,
              event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty else { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        guard key >= 0, key <= 50 else { return false }
        let shift = event.flags.contains(.maskShift)
        let caps = event.flags.contains(.maskAlphaShift)
        let character: Character?
        if let translate {
            character = translate(UInt16(key), shift, caps)
        } else {
            guard let layout = LayoutSwitcher.installedLayouts().first(where: {
                LayoutSwitcher.sourceID($0) == confirmedLayoutID
            }) else { return false }
            character = DynamicKeyMapping.characterForKeycode(UInt16(key), layout: layout, shift: shift, caps: caps)
        }
        guard let character, !character.isNewline else { return false }
        let units = Array(String(character).utf16)
        units.withUnsafeBufferPointer {
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
        }
        RuntimeDiagnostics.record(.heldInputRecoded)
        return true
    }
}
