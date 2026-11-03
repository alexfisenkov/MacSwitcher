import Foundation

/// The input gate can be unavailable even while its tap object still exists.
/// Do not use nativeInputTransportAvailable here: listen-only taps deliberately
/// have no native gate but still need to remain healthy.
struct NativeTapRecoveryStatus {
    let tapPresent: Bool
    let tapEnabled: Bool
    let fenceAvailable: Bool

    var needsRecovery: Bool { !tapPresent || !tapEnabled || !fenceAvailable }
}

/// Keeps one delayed tap restart outstanding after a transient start failure.
/// The caller owns the actual tap and decides when monitoring is active.
@MainActor
final class MonitoringTapRecovery {
    private let isActive: () -> Bool
    private let reconfigure: () -> Bool
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let retryInterval: TimeInterval
    private var generation: UInt64 = 0
    private(set) var retryScheduled = false
    private var stopped = false

    init(retryInterval: TimeInterval = 3,
         isActive: @escaping () -> Bool,
         reconfigure: @escaping () -> Bool,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void) {
        self.retryInterval = retryInterval
        self.isActive = isActive
        self.reconfigure = reconfigure
        self.schedule = schedule
    }

    /// Settings changes may request an immediate attempt even with a retry queued.
    func request() {
        guard !stopped, isActive() else { return }
        if reconfigure() {
            generation &+= 1
            retryScheduled = false
            return
        }
        guard !retryScheduled else { return }
        retryScheduled = true
        generation &+= 1
        let scheduledGeneration = generation
        schedule(retryInterval) { [weak self] in
            guard let self, self.retryScheduled,
                  self.generation == scheduledGeneration else { return }
            self.retryScheduled = false
            guard !self.stopped, self.isActive() else { return }
            self.request()
        }
    }

    func poll(needsRecovery: Bool) {
        guard needsRecovery, !retryScheduled else { return }
        request()
    }

    func stop() {
        stopped = true
        generation &+= 1
        retryScheduled = false
    }
}
