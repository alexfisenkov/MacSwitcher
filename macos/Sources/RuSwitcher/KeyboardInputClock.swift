import Darwin
import Dispatch

/// One timestamp sample at the tap boundary, before a callback can wait on the input fence.
/// CGEvent timestamps are documented in nanoseconds, but a clock with another unit must
/// never be compared directly with DispatchTime's uptime nanoseconds.
struct KeyboardInputClock: Sendable {
    let eventTimestamp: UInt64?
    let receivedAt: UInt64

    private static let maximumEventAge: UInt64 = 1_000_000_000
    private static let hostTimebase: (numerator: UInt32, denominator: UInt32) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS else { return (0, 0) }
        return (info.numer, info.denom)
    }()

    static func capture(rawTimestamp: UInt64) -> Self {
        Self(rawTimestamp: rawTimestamp, receivedAt: DispatchTime.now().uptimeNanoseconds,
             numerator: hostTimebase.numerator, denominator: hostTimebase.denominator)
    }

    /// Injection seam shared with the production callback. An ambiguous or stale clock
    /// has no event chronology; gesture timing can still use `receivedAt`.
    init(rawTimestamp: UInt64, receivedAt: UInt64, numerator: UInt32, denominator: UInt32) {
        self.receivedAt = receivedAt
        guard rawTimestamp > 0 else { eventTimestamp = nil; return }

        let asNanoseconds = Self.plausible(rawTimestamp, at: receivedAt) ? rawTimestamp : nil
        var asMachNanoseconds: UInt64?
        if numerator > 0, denominator > 0 {
            let (product, overflow) = rawTimestamp.multipliedReportingOverflow(by: UInt64(numerator))
            if !overflow {
                let scaled = product / UInt64(denominator)
                if Self.plausible(scaled, at: receivedAt) { asMachNanoseconds = scaled }
            }
        }

        switch (asNanoseconds, asMachNanoseconds) {
        case let (nanoseconds?, nil), let (nil, nanoseconds?): eventTimestamp = nanoseconds
        case let (nanoseconds?, scaled?) where nanoseconds == scaled: eventTimestamp = nanoseconds
        default: eventTimestamp = nil
        }
    }

    private static func plausible(_ timestamp: UInt64, at receivedAt: UInt64) -> Bool {
        timestamp > 0 && timestamp <= receivedAt && receivedAt - timestamp <= maximumEventAge
    }
}
