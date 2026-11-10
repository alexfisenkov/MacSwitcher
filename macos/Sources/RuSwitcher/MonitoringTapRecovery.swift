import Foundation

/// The input gate can be unavailable even while its tap object still exists.
/// Do not use nativeInputTransportAvailable here: listen-only taps deliberately
/// have no native gate but still need to remain healthy.
struct NativeTapRecoveryStatus {
    let tapPresent: Bool
    let tapEnabled: Bool
    let fenceAvailable: Bool
    let fenceRequired: Bool

    init(tapPresent: Bool, tapEnabled: Bool, fenceAvailable: Bool,
         fenceRequired: Bool = true) {
        self.tapPresent = tapPresent
        self.tapEnabled = tapEnabled
        self.fenceAvailable = fenceAvailable
        self.fenceRequired = fenceRequired
    }

    var needsRecovery: Bool { !tapPresent || !tapEnabled || (fenceRequired && !fenceAvailable) }
}

/// Keeps one delayed tap restart outstanding after a transient start failure.
/// The caller owns the actual tap and decides when monitoring is active.
@MainActor
final class MonitoringTapRecovery {
    private let isActive: () -> Bool
    private let mayReconfigure: () -> Bool
    private let reconfigure: () -> Bool
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let retryInterval: TimeInterval
    private let maxFailedStarts: Int
    private var generation: UInt64 = 0
    private(set) var retryScheduled = false
    private var deferredRequest = false
    private var deferredExplicitRequest = false
    private(set) var failedStartCount = 0
    var isExhausted: Bool { failedStartCount >= maxFailedStarts }
    private var stopped = false

    init(retryInterval: TimeInterval = 3,
         maxFailedStarts: Int = 5,
         isActive: @escaping () -> Bool,
         mayReconfigure: @escaping () -> Bool = { true },
         reconfigure: @escaping () -> Bool,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void) {
        self.retryInterval = retryInterval
        self.maxFailedStarts = max(1, maxFailedStarts)
        self.isActive = isActive
        self.mayReconfigure = mayReconfigure
        self.reconfigure = reconfigure
        self.schedule = schedule
    }

    /// Only an explicit user setting/check or known system transition starts a
    /// new budget. Polls and scheduled retries never reset an exhausted one.
    func request(allowNewEpisode: Bool = false) {
        guard !stopped, isActive() else { return }
        guard mayReconfigure() else {
            deferredRequest = true
            deferredExplicitRequest = deferredExplicitRequest || allowNewEpisode
            return
        }
        if allowNewEpisode || deferredExplicitRequest {
            failedStartCount = 0
            generation &+= 1
            retryScheduled = false
        }
        deferredRequest = false
        deferredExplicitRequest = false
        guard !isExhausted else { return }
        if reconfigure() {
            failedStartCount = 0
            generation &+= 1
            retryScheduled = false
            return
        }
        failedStartCount += 1
        guard !isExhausted else { return }
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
        if deferredRequest && (needsRecovery || deferredExplicitRequest) {
            request(allowNewEpisode: deferredExplicitRequest)
            return
        }
        guard needsRecovery else {
            if failedStartCount > 0 || retryScheduled {
                failedStartCount = 0
                retryScheduled = false
                generation &+= 1
            }
            deferredRequest = false
            deferredExplicitRequest = false
            return
        }
        guard needsRecovery, !retryScheduled else { return }
        request()
    }

    func stop() {
        stopped = true
        generation &+= 1
        retryScheduled = false
        deferredRequest = false
        deferredExplicitRequest = false
    }
}
