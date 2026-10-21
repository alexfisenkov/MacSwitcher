import ApplicationServices
import CoreGraphics
import Foundation

/// Non-UI lifecycle probe. It never requests permissions or posts input events.
@MainActor
enum EventTapLifecycleDiagnostics {
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.contains("--self-test-event-tap-host") else { return nil }
        var report = Report(axTrusted: AXIsProcessTrusted(), listenAllowed: CGPreflightListenEventAccess())
        guard report.axTrusted, report.listenAllowed else {
            report.status = "permissionUnavailable"
            return emit(report) ? 2 : 1
        }
        let counters = Counters()
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let host = KeyboardEventTapHost.start(location: .cghidEventTap, options: .defaultTap,
            mask: mask, handler: { _, type, event in
                counters.record(type: type)
                return Unmanaged.passUnretained(event)
            }) else {
            report.status = "hostUnavailable"
            _ = emit(report)
            return 1
        }
        report.ready = true
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + 2.0
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.010)) {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        report.durationSeconds = ProcessInfo.processInfo.systemUptime - startedAt
        report.valid = CFMachPortIsValid(host.tap)
        report.enabled = CGEvent.tapIsEnabled(tap: host.tap)
        host.stop()
        let snapshot = counters.snapshot()
        report.callbacks = snapshot.callbacks
        report.disabledTimeout = snapshot.disabledTimeout
        report.disabledUserInput = snapshot.disabledUserInput
        report.callbackOnMain = snapshot.callbackOnMain
        let healthy = report.valid && report.enabled && snapshot.disabledTimeout == 0
            && snapshot.disabledUserInput == 0 && snapshot.callbackOnMain == 0
        report.status = healthy ? "healthy" : "unhealthy"
        return emit(report) ? (healthy ? 0 : 1) : 1
    }

    private struct Report: Encodable {
        let axTrusted: Bool
        let listenAllowed: Bool
        var status = "starting"
        var ready = false
        var valid = false
        var enabled = false
        var callbacks = 0
        var disabledTimeout = 0
        var disabledUserInput = 0
        var callbackOnMain = 0
        var durationSeconds = 0.0
    }

    private struct Snapshot: Sendable {
        var callbacks = 0
        var disabledTimeout = 0
        var disabledUserInput = 0
        var callbackOnMain = 0
    }

    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Snapshot()

        func record(type: CGEventType) {
            lock.lock()
            defer { lock.unlock() }
            value.callbacks += 1
            if type == .tapDisabledByTimeout { value.disabledTimeout += 1 }
            if type == .tapDisabledByUserInput { value.disabledUserInput += 1 }
            if Thread.isMainThread { value.callbackOnMain += 1 }
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func emit(_ report: Report) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return false }
        print(String(decoding: data, as: UTF8.self))
        return true
    }
}
