import CoreGraphics
import Foundation

/// Owns one tap and its run loop. stop never joins a callback that may need main.
final class KeyboardEventTapHost: @unchecked Sendable {
    private typealias Handler = (CGEventTapProxy, CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    private let handler: Handler
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var stopping = false

    /// Assigned before the host is published and kept alive through thread exit.
    var tap: CFMachPort { eventTap! }

    private init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Return the original event unretained; a distinct replacement must be +1.
    static func start(
        location: CGEventTapLocation,
        options: CGEventTapOptions,
        mask: CGEventMask,
        handler: @escaping (CGEventTapProxy, CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    ) -> KeyboardEventTapHost? {
        let host = KeyboardEventTapHost(handler: handler)
        guard let tap = CGEvent.tapCreate(
            tap: location, place: .tailAppendEventTap, options: options,
            eventsOfInterest: mask, callback: keyboardEventTapHostCallback,
            userInfo: Unmanaged.passUnretained(host).toOpaque()
        ) else { return nil }
        host.eventTap = tap
        // New taps are already enabled. Disabling here queues a user-disabled
        // notification that would invalidate the newly created input fence.
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            host.stop()
            return nil
        }
        host.source = source

        // The running Thread retains its closure/host; host does not retain the
        // Thread, including when readiness times out before the thread starts.
        let thread = Thread { host.run() }
        thread.name = "MacSwitcher keyboard event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        guard host.ready.wait(timeout: .now() + .milliseconds(500)) == .success,
              !host.isStopping else {
            host.stop()
            return nil
        }
        return host
    }

    func stop() {
        lock.lock()
        stopping = true
        let loop = runLoop
        lock.unlock()

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let loop {
            // Also handles stop between readiness and CFRunLoopRun: a stop
            // requested before a run starts need not stop that future run.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
        }
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func run() {
        let loop = CFRunLoopGetCurrent()
        lock.lock()
        guard !stopping, let eventTap, let source else {
            lock.unlock()
            ready.signal()
            return
        }
        runLoop = loop
        lock.unlock()
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        ready.signal()

        CFRunLoopRun()

        lock.lock()
        stopping = true
        runLoop = nil
        lock.unlock()
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFMachPortInvalidate(eventTap)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFRunLoopSourceInvalidate(source)
    }

    fileprivate func handle(
        proxy: CGEventTapProxy, type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Never hold the lifecycle lock while the handler may wait for main.
        guard !isStopping else { return Unmanaged.passUnretained(event) }
        return handler(proxy, type, event)
    }
}

private func keyboardEventTapHostCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let host = Unmanaged<KeyboardEventTapHost>.fromOpaque(userInfo).takeUnretainedValue()
    return host.handle(proxy: proxy, type: type, event: event)
}
