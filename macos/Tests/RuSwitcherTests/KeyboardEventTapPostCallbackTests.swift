import CoreFoundation
import CoreGraphics
import XCTest
@testable import RuSwitcher

final class KeyboardEventTapPostCallbackTests: XCTestCase {
    private final class CallbackState {
        var inCallback = false
        var delivered = false
        var deliveredDuringCallback = false
    }

    func testPostCallbackDeliveryRunsAfterRealRunLoopSourceReturns() {
        let state = CallbackState()
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(state).toOpaque()
        context.perform = { raw in
            guard let raw else { return }
            let state = Unmanaged<CallbackState>.fromOpaque(raw).takeUnretainedValue()
            state.inCallback = true
            KeyboardEventTapHost.performAfterCurrentCallback(on: CFRunLoopGetCurrent()) {
                state.deliveredDuringCallback = state.inCallback
                state.delivered = true
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            XCTAssertFalse(state.delivered)
            state.inCallback = false
        }
        let loop = CFRunLoopGetCurrent()
        let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)!
        CFRunLoopAddSource(loop, source, .defaultMode)
        defer {
            CFRunLoopRemoveSource(loop, source, .defaultMode)
            CFRunLoopSourceInvalidate(source)
        }
        CFRunLoopSourceSignal(source)
        CFRunLoopWakeUp(loop)
        CFRunLoopRunInMode(.defaultMode, 1, false)
        XCTAssertTrue(state.delivered)
        XCTAssertFalse(state.deliveredDuringCallback)
    }

    @MainActor
    func testCapturedGestureDeliversOnceAndDropsStaleRevisionOrTap() {
        let monitor = KeyboardMonitor()
        let fence = NSObject()
        let host = NSObject()
        let replacementFence = NSObject()
        let replacementHost = NSObject()
        let direction = CombinedShiftContext(sourceLayoutID: "test.en", targetLayoutID: "test.ru")
        func request() -> CombinedShiftRequest {
            CombinedShiftRequest(action: .convert(direction), wordContext: direction,
                wordKeys: [], prevWordKeys: [], lineKeys: [], lineSourceLayoutID: nil,
                boundaryCount: 0, reconvert: false, inputRevision: monitor.inputRevision,
                frontProcessID: 42, focus: nil)
        }
        func delivery(_ request: CombinedShiftRequest) -> DeferredCombinedShiftConversion {
            DeferredCombinedShiftConversion(request: request,
                fenceIdentity: ObjectIdentifier(fence), hostIdentity: ObjectIdentifier(host))
        }
        var delivered = 0
        let first = delivery(request())
        for _ in 0..<2 {
            first.deliver(currentFenceIdentity: ObjectIdentifier(fence),
                currentHostIdentity: ObjectIdentifier(host), currentRevision: monitor.inputRevision,
                transportAvailable: true) { _ in delivered += 1 }
        }
        XCTAssertEqual(delivered, 1, "One callback can dispatch its captured request only once")

        let old = delivery(request())
        monitor.handleKeyDown(keyCode: 5, flags: [])
        old.deliver(currentFenceIdentity: ObjectIdentifier(fence),
            currentHostIdentity: ObjectIdentifier(host), currentRevision: monitor.inputRevision,
            transportAvailable: true) { _ in delivered += 1 }
        XCTAssertEqual(delivered, 1, "New physical input retires the old gesture")

        let staleTap = delivery(request())
        staleTap.deliver(currentFenceIdentity: ObjectIdentifier(replacementFence),
            currentHostIdentity: ObjectIdentifier(host), currentRevision: monitor.inputRevision,
            transportAvailable: true) { _ in delivered += 1 }
        let staleHost = delivery(request())
        staleHost.deliver(currentFenceIdentity: ObjectIdentifier(fence),
            currentHostIdentity: ObjectIdentifier(replacementHost), currentRevision: monitor.inputRevision,
            transportAvailable: true) { _ in delivered += 1 }
        XCTAssertEqual(delivered, 1, "Stop or reconfigure must retire the old host/fence")

        let nextWord = delivery(request())
        nextWord.deliver(currentFenceIdentity: ObjectIdentifier(fence),
            currentHostIdentity: ObjectIdentifier(host), currentRevision: monitor.inputRevision,
            transportAvailable: true) { _ in delivered += 1 }
        XCTAssertEqual(delivered, 2, "A new word has a fresh gesture snapshot")
    }
}
