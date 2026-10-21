import CoreGraphics
import Foundation

/// A complete immutable native sequence, built before field admission. The
/// key-up for every key-down exists before the first event is queued.
@MainActor
struct NativePreparedEventBatch {
    let operations: [NativeFieldEditOperation]
    let events: [CGEvent]

    func post(to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        guard processID > 0 else { return false }
        return NativeFieldBatchPoster.post(eventCount: events.count, mayBegin: whileCurrent) {
            events[$0].postToPid(processID)
        }
    }
}

/// Preallocated, marked, PID-only events. Ordinary replacement allocates at most
/// 54 events: selection phase, then Unicode plus non-text caret stabilization.
/// Legacy insert-first helpers retain their own explicitly requested transport.
@MainActor
struct NativeAutoEventTransport {
    let preparedSelection: NativePreparedEventBatch
    let preparedReplacement: NativePreparedEventBatch
    let preparedCancellation: NativePreparedEventBatch
    private let insertion: [CGEvent]
    private let removal: [CGEvent]

    init?(original: String, replacement: String, prepareLegacyRemoval: Bool = false) {
        guard !original.isEmpty, original.count == replacement.count,
              original.utf16.count == original.count, replacement.utf16.count == replacement.count,
              replacement.utf16.count <= NativeFieldEditPlan.maximumEditUnits,
              let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = kRuSwitcherEventMarker
        source.localEventsSuppressionInterval = 0
        func pair(_ code: CGKeyCode, flags: CGEventFlags = []) -> [CGEvent]? {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return nil }
            for event in [down, up] {
                event.flags = flags
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
        var selected: [CGEvent] = []
        selected.reserveCapacity(2 * original.count)
        for _ in 0..<original.count {
            guard let events = pair(123, flags: .maskShift) else { return nil }
            selected.append(contentsOf: events)
        }
        guard let stabilizeLeft = pair(123, flags: .maskShift), let collapseRight = pair(124) else { return nil }
        preparedSelection = NativePreparedEventBatch(
            operations: Array(repeating: .selectPreviousCharacter, count: original.count), events: selected)
        preparedReplacement = NativePreparedEventBatch(
            operations: [.insertReplacement, .selectPreviousCharacter, .right],
            events: unicode + stabilizeLeft + collapseRight)
        // Reuse the exact preallocated non-text pairs; cancellation is never a
        // second data write and keeps a previously collapsed caret unchanged.
        preparedCancellation = NativePreparedEventBatch(
            operations: [.selectPreviousCharacter, .right], events: stabilizeLeft + collapseRight)
        insertion = unicode
        var navigation: [CGEvent] = []
        if prepareLegacyRemoval {
            for code in [CGKeyCode(123), 51, 124] {
                for _ in 0..<original.count {
                    guard let events = pair(code) else { return nil }
                    navigation.append(contentsOf: events)
                }
            }
        }
        removal = navigation
    }

    func postInsertion(to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        postLegacy(insertion, to: processID, whileCurrent: whileCurrent)
    }

    func postRemoval(to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        guard !removal.isEmpty else { return false }
        return postLegacy(removal, to: processID, whileCurrent: whileCurrent)
    }

    func postBatch(_ operations: [NativeFieldEditOperation], to processID: Int32,
                   whileCurrent: () -> Bool) -> Bool {
        if operations == preparedSelection.operations {
            return preparedSelection.post(to: processID, whileCurrent: whileCurrent)
        }
        if operations == preparedReplacement.operations {
            return preparedReplacement.post(to: processID, whileCurrent: whileCurrent)
        }
        return false
    }

    func cancelPreparedSelection(to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        preparedCancellation.post(to: processID, whileCurrent: whileCurrent)
    }

    private func postLegacy(_ events: [CGEvent], to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        guard processID > 0 else { return false }
        for offset in stride(from: 0, to: events.count, by: 2) {
            guard NativeFieldKeyPairPoster.post(mayContinue: whileCurrent,
                keyDown: { events[offset].postToPid(processID) },
                keyUp: { events[offset + 1].postToPid(processID) }) else { return false }
        }
        return true // queued, never interpreted as delivery confirmation
    }
}

/// Prepared-only selection transport. One Unicode key pair carries the entire
/// replacement; constructing or inspecting it never posts input. The CGEvent
/// payload round-trip is preparation evidence, not target-delivery evidence.
@MainActor
struct NativeSelectedTextEventTransport {
    let events: [CGEvent]

    init?(replacement: String) {
        guard !replacement.isEmpty,
              replacement.utf16.count <= NativeFieldEditPlan.maximumSelectedReplacementUnits else { return nil }
        let units = Array(replacement.utf16)
        guard NativeFieldEditPlan.isWellFormedUTF16(units),
              let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = kRuSwitcherEventMarker
        source.localEventsSuppressionInterval = 0
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: kRuSwitcherEventMarker)
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
            }
            guard CombinedShiftUnicode.payloadMatches(event, expected: units) else { return nil }
        }
        events = [down, up]
    }

    func post(to processID: Int32, whileCurrent: () -> Bool) -> Bool {
        guard processID > 0 else { return false }
        return NativeFieldBatchPoster.post(eventCount: events.count, mayBegin: whileCurrent) {
            events[$0].postToPid(processID)
        }
    }
}
