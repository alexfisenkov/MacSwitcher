import Foundation

/// Circuit breaker for automatic corrections. Manual double Shift never asks it.
/// Idea from Keyboop's anti-resonance guard (MIT), see NOTICE.md; stores no text:
/// only hashes of the last pair are compared, and nothing is logged here but a code.
final class AutoCorrectionLoopGuard {
    static let reversalWindow: TimeInterval = 0.7
    static let burstWindow: TimeInterval = 1.0
    static let maxPerBurst = 6
    static let freezeDuration: TimeInterval = 2.5

    private struct Edit { let original: Int; let replacement: Int; let at: TimeInterval }
    private var recent: [Edit] = []
    private var frozenUntil: TimeInterval?
    private let onTrip: () -> Void

    init(onTrip: @escaping () -> Void = { RuntimeDiagnostics.record(.autoLoopGuardTripped) }) {
        self.onTrip = onTrip
    }

    /// Whether another automatic correction may start now. When the candidate pair is
    /// given, a direct reversal of the previous correction trips the guard before any write.
    func allow(now: TimeInterval, original: String? = nil, replacement: String? = nil) -> Bool {
        if let until = frozenUntil {
            if now < until { return false }
            frozenUntil = nil
        }
        recent.removeAll { now - $0.at > Self.burstWindow }
        if recent.count >= Self.maxPerBurst { trip(now); return false }
        if let original, let replacement, let last = recent.last,
           now - last.at <= Self.reversalWindow,
           last.original == replacement.hashValue, last.replacement == original.hashValue {
            trip(now); return false
        }
        return true
    }

    /// Call after an automatic correction was confirmed.
    func record(original: String, replacement: String, now: TimeInterval) {
        recent.removeAll { now - $0.at > Self.burstWindow }
        if let last = recent.last, now - last.at <= Self.reversalWindow,
           last.original == replacement.hashValue, last.replacement == original.hashValue {
            trip(now)
        }
        recent.append(Edit(original: original.hashValue, replacement: replacement.hashValue, at: now))
        if recent.count > Self.maxPerBurst { trip(now) }
    }

    private func trip(_ now: TimeInterval) {
        guard frozenUntil == nil || now >= frozenUntil! else { return }
        frozenUntil = now + Self.freezeDuration
        recent.removeAll()
        onTrip()
    }
}
