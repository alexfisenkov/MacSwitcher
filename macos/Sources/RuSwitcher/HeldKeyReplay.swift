import Carbon
import CoreGraphics
import Foundation

/// The OS still owns this held physical event. Only its printable payload is
/// regenerated after the transaction's source has been independently observed.
enum HeldKeyReplay {
    /// Shared tap admission boundary. The source closure captures one actual
    /// source identity, which is used for both decoding and the monitor receipt.
    static func refreshForForwarding(_ event: CGEvent, needsSourceRefresh: Bool, remoteDesktopMode: Bool,
        observeSource: () -> String = LayoutSwitcher.currentLayoutID,
        translate: ((String, UInt16, Bool, Bool) -> Character?)? = nil) -> String? {
        // Rewrite only input associated with an actual correction/source
        // transition. Idle remappers and software keyboards own their payloads.
        guard needsSourceRefresh, !remoteDesktopMode,
              eligibleKeyCode(event) != nil else { return nil }
        return refreshUsingObservedSource(event, observeSource: observeSource, translate: translate)
    }

    /// Even a source request that was not acknowledged within its budget may
    /// complete later. Decode each delayed event using the source observed now,
    /// and return that immutable identity with its payload to the monitor.
    static func refreshUsingObservedSource(_ event: CGEvent,
        observeSource: () -> String = LayoutSwitcher.currentLayoutID,
        translate: ((String, UInt16, Bool, Bool) -> Character?)? = nil) -> String? {
        guard eligibleKeyCode(event) != nil else { return nil }
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
        guard let key = eligibleKeyCode(event), !confirmedLayoutID.isEmpty,
              currentLayoutID() == confirmedLayoutID else { return false }
        let shift = event.flags.contains(.maskShift)
        let caps = event.flags.contains(.maskAlphaShift)
        let character: Character?
        if let translate {
            character = translate(key, shift, caps)
        } else {
            guard let layout = LayoutSwitcher.installedLayouts().first(where: {
                LayoutSwitcher.sourceID($0) == confirmedLayoutID
            }) else { return false }
            character = plainCharacterForKeycode(key, layout: layout, shift: shift, caps: caps)
        }
        guard let character, isPlainCharacter(character) else { return false }
        let units = Array(String(character).utf16)
        units.withUnsafeBufferPointer {
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
        }
        RuntimeDiagnostics.record(.heldInputRecoded)
        return true
    }

    /// Preserve composition, IME payloads, shortcuts and unsupported characters.
    /// This boundary must not synthesize a character for an empty/dead-key event.
    private static func eligibleKeyCode(_ event: CGEvent) -> UInt16? {
        guard event.type == .keyDown,
              event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty else { return nil }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        guard key >= 0, key <= 50 else { return nil }
        var units = [UniChar](repeating: 0, count: 2)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        guard length == 1, let scalar = UnicodeScalar(units[0]),
              isPlainCharacter(Character(scalar)) else { return nil }
        return UInt16(key)
    }

    private static func isPlainCharacter(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        if (0x20...0x7E).contains(scalar.value) { return true }
        guard (0x0400...0x052F).contains(scalar.value) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter: return true
        default: return false
        }
    }

    /// Unlike conversion mapping, forwarding cannot disable dead keys or take
    /// only the first unit of a composed translation. Decode the captured source
    /// with composition enabled and accept exactly one standalone code unit.
    private static func plainCharacterForKeycode(_ key: UInt16, layout: TISInputSource,
                                                shift: Bool, caps: Bool) -> Character? {
        guard let pointer = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var modifiers: UInt32 = shift ? (UInt32(shiftKey >> 8) & 0xFF) : 0
        if caps { modifiers |= UInt32(alphaLock >> 8) & 0xFF }
        var deadState: UInt32 = 0
        var units = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let keyboard = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(keyboard, key, UInt16(kUCKeyActionDown), modifiers,
                UInt32(LMGetKbdType()), 0, &deadState, units.count, &length, &units)
        }
        guard status == noErr, deadState == 0, length == 1,
              let scalar = UnicodeScalar(units[0]) else { return nil }
        return Character(scalar)
    }
}
