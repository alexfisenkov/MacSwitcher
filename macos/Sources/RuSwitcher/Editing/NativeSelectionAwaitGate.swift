/// A selected-text lookup may suspend without changing the keyboard input
/// revision. Every later Shift action invalidates its ticket before another
/// transaction can adopt the old field snapshot.
struct NativeSelectionAwaitGate {
    private var generation: UInt64 = 0

    mutating func nextAction() -> UInt64 {
        generation &+= 1
        return generation
    }

    func permits(_ ticket: UInt64, cancelled: Bool) -> Bool {
        !cancelled && ticket == generation
    }
}
