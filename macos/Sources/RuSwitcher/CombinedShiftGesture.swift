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
    struct Configuration: Equatable, Sendable {
        static let defaultDoubleWindowNanoseconds: UInt64 = 180_000_000
        static let allowedDoubleWindowNanoseconds: ClosedRange<UInt64> = 80_000_000...400_000_000
        let doubleWindowNanoseconds: UInt64

        init(doubleWindowNanoseconds: UInt64 = Self.defaultDoubleWindowNanoseconds) {
            self.doubleWindowNanoseconds = Self.allowedDoubleWindowNanoseconds.contains(doubleWindowNanoseconds)
                ? doubleWindowNanoseconds : Self.defaultDoubleWindowNanoseconds
        }
    }

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
    // A double must finish quickly; pauses belong to independent solo switches.
    private let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

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
           timestamp - first.time <= configuration.doubleWindowNanoseconds {
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
