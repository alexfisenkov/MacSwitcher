/// Immutable layout direction captured before the first Shift changes the input source.
struct CombinedShiftContext: Equatable, Sendable {
    let sourceLayoutID: String
    let targetLayoutID: String

    var reversed: CombinedShiftContext {
        CombinedShiftContext(sourceLayoutID: targetLayoutID, targetLayoutID: sourceLayoutID)
    }
}

/// Pure gesture recognizer. Times are CGEvent's monotonic nanoseconds; no timers or event injection.
struct CombinedShiftGesture {
    enum Side: Equatable { case left, right }
    enum Action: Equatable, Sendable {
        case switchLayout(CombinedShiftContext)
        case convert(CombinedShiftContext)
    }

    private struct Press {
        let side: Side
        let time: UInt64
        let context: CombinedShiftContext
    }
    private struct Tap {
        let time: UInt64
        let context: CombinedShiftContext
    }
    private var pressed: Press?
    private var firstTap: Tap?
    private let soloLimit: UInt64 = 250_000_000
    private let doubleWindow: UInt64 = 400_000_000

    mutating func press(_ side: Side, at timestamp: UInt64, context: CombinedShiftContext) {
        guard pressed == nil else { interrupt(); return }  // overlapping Shift keys are a chord
        if let first = firstTap, timestamp < first.time { interrupt() }
        pressed = Press(side: side, time: timestamp, context: context)
    }

    mutating func release(_ side: Side, at timestamp: UInt64) -> Action? {
        guard let press = pressed, press.side == side, timestamp >= press.time,
              timestamp - press.time <= soloLimit else {
            interrupt()
            return nil
        }
        pressed = nil
        if let first = firstTap, timestamp >= first.time,
           timestamp - first.time <= doubleWindow {
            firstTap = nil
            return .convert(first.context)  // no second generic layout toggle
        }
        firstTap = Tap(time: timestamp, context: press.context)
        return .switchLayout(press.context)  // no wait to discover whether another tap follows
    }

    mutating func interrupt() {
        pressed = nil
        firstTap = nil
    }
}
