/// Immutable layout direction captured before the first Shift changes the input source.
struct CombinedShiftContext: Equatable, Sendable {
    let sourceLayoutID: String
    let targetLayoutID: String

    var reversed: CombinedShiftContext {
        CombinedShiftContext(sourceLayoutID: targetLayoutID, targetLayoutID: sourceLayoutID)
    }
}

/// Pure gesture recognizer. Event and callback arrival times share uptime nanoseconds.
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
        let clock: KeyboardInputClock
        let context: CombinedShiftContext
    }
    private struct Tap {
        let clock: KeyboardInputClock
        let context: CombinedShiftContext
    }
    private var pressed: Press?
    private var firstTap: Tap?
    private let soloLimit: UInt64 = 250_000_000
    // Small callback scheduling skew is allowed only when the event clock advances.
    private static let maximumArrivalSkew: UInt64 = 50_000_000
    // A double must finish quickly; pauses belong to independent solo switches.
    private let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func press(_ side: Side, at timestamp: UInt64, context: CombinedShiftContext) {
        press(side, clock: KeyboardInputClock(rawTimestamp: timestamp, receivedAt: timestamp,
            numerator: 1, denominator: 1), context: context)
    }

    mutating func press(_ side: Side, clock: KeyboardInputClock, context: CombinedShiftContext) {
        guard pressed == nil else { interrupt(); return }  // overlapping Shift keys are a chord
        if let first = firstTap, clock.receivedAt < first.clock.receivedAt { interrupt() }
        pressed = Press(side: side, clock: clock, context: context)
    }

    mutating func release(_ side: Side, at timestamp: UInt64) -> Action? {
        release(side, clock: KeyboardInputClock(rawTimestamp: timestamp, receivedAt: timestamp,
            numerator: 1, denominator: 1))
    }

    mutating func release(_ side: Side, clock: KeyboardInputClock) -> Action? {
        guard let press = pressed, press.side == side,
              Self.qualifiedHold(clock, after: press.clock, limit: soloLimit) else {
            interrupt()
            return nil
        }
        pressed = nil
        if let first = firstTap,
           Self.within(clock, after: first.clock, limit: configuration.doubleWindowNanoseconds) {
            firstTap = nil
            return .convert(first.context)  // no second generic layout toggle
        }
        firstTap = Tap(clock: clock, context: press.context)
        return .switchLayout(press.context)  // no wait to discover whether another tap follows
    }

    private static func within(_ later: KeyboardInputClock, after earlier: KeyboardInputClock,
                               limit: UInt64) -> Bool {
        guard later.receivedAt >= earlier.receivedAt else { return false }
        let arrivalGap = later.receivedAt - earlier.receivedAt
        // A constant stamp supplies no chronology, even if its value is initially
        // plausible. Arrival still distinguishes fast doubles from separate solos.
        if let previous = earlier.eventTimestamp, let current = later.eventTimestamp {
            guard current >= previous else { return false }
            let eventGap = current - previous
            if eventGap == 0 { return arrivalGap <= limit }
            guard eventGap <= limit else { return false }
            // Preserve a true boundary tap despite a small callback delay, but never
            // let a compressed/incoherent event clock hide a long arrival pause.
            return arrivalGap <= eventGap + maximumArrivalSkew
        }
        return arrivalGap <= limit
    }

    private static func qualifiedHold(_ release: KeyboardInputClock, after press: KeyboardInputClock,
                                      limit: UInt64) -> Bool {
        guard release.receivedAt >= press.receivedAt else { return false }
        if let down = press.eventTimestamp, let up = release.eventTimestamp {
            guard up >= down else { return false }
            let eventHold = up - down
            // A successful fence may hold the down callback while the matching up
            // waits behind it. Its arrival gap then includes lease time; the event
            // clock still measures the physical hold. A constant stamp does not.
            if eventHold > 0 { return eventHold <= limit }
        }
        return release.receivedAt - press.receivedAt <= limit
    }

    mutating func interrupt() {
        pressed = nil
        firstTap = nil
    }
}
