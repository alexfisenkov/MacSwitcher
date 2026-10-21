import Foundation

/// Read-only observation of the fixed original field. Text is the exact requested
/// UTF-16 span beginning at the original suffix's start; caret is field-absolute.
struct NativeAutomaticTextObservation: Equatable {
    let textFromOriginalStart: String
    let caretUTF16Location: Int
    let selectionLength: Int
}

enum NativeAutomaticTextEditResult: Equatable {
    case confirmed
    case refused
    /// The expected intermediate/result remains available only for explicit,
    /// exact-match recovery. This does not assert that the text was delivered.
    case uncertain(recoveryText: String)
}

/// All keyboard events must be prepared before entering the transaction. The
/// transport targets one PID and tags its own events. Each posting closure must
/// check its cheap barrier/PID/revision/secure-input/deadline gate before each
/// key-down, always pair a posted key-down with key-up, report partial posting,
/// and never use a global fallback.
/// deleteOriginal posts Left×n, Backspace×n, Right×n without waits between events.
/// No closure may write an AX selection/value or use the user's clipboard.
@MainActor
struct NativeAutomaticTextAccess {
    let isValid: () -> Bool
    let inputBarrierIsActive: () -> Bool
    let observe: (_ utf16Length: Int) -> NativeAutomaticTextObservation?
    let insertReplacement: () -> Bool
    let deleteOriginal: () -> Bool
    let pause: (_ seconds: TimeInterval) -> Void
    let now: () -> TimeInterval
}

/// Synchronous insert-first experiment. Main-actor execution and a configured
/// active tap are eligibility checks; exclusion of concurrent physical or
/// programmatic input is NOT proven. This does not make AX/DOM atomic. An
/// unverified result stops new requests; queued events may still arrive.
/// There is no deletion retry, alternate writer, or automatic rollback.
@MainActor
enum NativeAutomaticTextEditor {
    static let maximumUnits = 20
    static let maximumDuration: TimeInterval = 0.100
    private static let pollInterval: TimeInterval = 0.001
    private static let maximumObservations = 100

    static func replace(original: String, replacement: String, originalStartUTF16: Int,
                        access: NativeAutomaticTextAccess) -> NativeAutomaticTextEditResult {
        guard original != replacement, isSimpleText(original), isSimpleText(replacement),
              original.count == replacement.count,
              original.utf16.count == replacement.utf16.count,
              originalStartUTF16 >= 0 else { return .refused }
        let length = original.utf16.count
        guard originalStartUTF16 <= Int.max - 2 * length else { return .refused }
        let originalCaret = originalStartUTF16 + length
        let duplicate = original + replacement
        let duplicateCaret = originalCaret + length
        let started = access.now()
        guard started.isFinite, started >= 0,
              (started + maximumDuration).isFinite else { return .refused }
        var lastTime = started
        let deadline = started + maximumDuration

        func withinDeadline() -> Bool {
            let time = access.now()
            guard time.isFinite, time >= lastTime, time < deadline else { return false }
            lastTime = time
            return true
        }

        func mayContinue() -> Bool {
            // Validation may involve bounded AX reads, so time and the active
            // input barrier are checked again after it returns.
            withinDeadline() && access.inputBarrierIsActive() && access.isValid()
                && access.inputBarrierIsActive() && withinDeadline()
        }

        func matches(_ text: String, caret: Int) -> Bool {
            guard mayContinue() else { return false }
            let observed = access.observe(text.utf16.count)
            guard mayContinue(), let observed else { return false }
            return observed.textFromOriginalStart == text
                && observed.caretUTF16Location == caret && observed.selectionLength == 0
        }

        func awaitReadback(_ text: String, caret: Int) -> Bool {
            for _ in 0..<maximumObservations {
                if matches(text, caret: caret) { return true }
                guard mayContinue() else { return false }
                // The attempt cap also prevents a broken injected clock/pause
                // from spinning forever. Production uses a monotonic clock.
                access.pause(min(pollInterval, max(0, deadline - lastTime)))
            }
            return false
        }

        guard matches(original, caret: originalCaret), mayContinue() else { return .refused }
        guard access.insertReplacement() else { return .uncertain(recoveryText: duplicate) }
        // The entire original plus the entire inserted copy, at the exact
        // collapsed caret, must be visible before a single Backspace is sent.
        guard awaitReadback(duplicate, caret: duplicateCaret), mayContinue() else {
            return .uncertain(recoveryText: duplicate)
        }
        guard access.deleteOriginal() else { return .uncertain(recoveryText: replacement) }
        guard awaitReadback(replacement, caret: originalCaret) else {
            return .uncertain(recoveryText: replacement)
        }
        return .confirmed
    }

    private static func isSimpleText(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maximumUnits,
              text.utf16.count == text.count else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            if (0x20...0x7E).contains(scalar.value) { return true }
            guard (0x0400...0x052F).contains(scalar.value) else { return false }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter: return true
            default: return false
            }
        }
    }
}
