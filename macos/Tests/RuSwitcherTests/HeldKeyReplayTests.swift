import CoreGraphics
import XCTest
@testable import RuSwitcher

final class HeldKeyReplayTests: XCTestCase {
    private func event(key: CGKeyCode = 17, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
        event.flags = flags
        let old: [UniChar] = [116]
        old.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: 1, unicodeString: $0.baseAddress) }
        return event
    }
    private func text(_ event: CGEvent) -> String {
        var units = [UniChar](repeating: 0, count: 8)
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        return String(decoding: units.prefix(count), as: UTF16.self)
    }

    func testQueuedOldSourcePayloadBecomesConfirmedRussianContinuation() {
        let next = event()
        XCTAssertTrue(HeldKeyReplay.rewrite(next, confirmedLayoutID: "ru", currentLayoutID: { "ru" },
            translate: { key, shift, caps in
                XCTAssertEqual(key, 17); XCTAssertFalse(shift); XCTAssertFalse(caps)
                return "е"
            }))
        XCTAssertEqual(text(next), "е")
        XCTAssertEqual(next.getIntegerValueField(.keyboardEventKeycode), 17)
    }

    func testShortcutsAndUnconfirmedSourceKeepTheirOriginalPayload() {
        for flags in [CGEventFlags.maskCommand, .maskControl, .maskAlternate] {
            let next = event(flags: flags)
            XCTAssertFalse(HeldKeyReplay.rewrite(next, confirmedLayoutID: "ru", currentLayoutID: { "ru" },
                translate: { _, _, _ in XCTFail("Shortcut must not become printable text"); return "е" }))
            XCTAssertEqual(text(next), "t")
        }
        let next = event()
        XCTAssertFalse(HeldKeyReplay.rewrite(next, confirmedLayoutID: "ru", currentLayoutID: { "en" },
            translate: { _, _, _ in XCTFail("Source was not confirmed"); return "е" }))
        XCTAssertEqual(text(next), "t")
    }

    func testShiftCapsAndKeyUpArePreserved() {
        let next = event(flags: [.maskShift, .maskAlphaShift])
        XCTAssertTrue(HeldKeyReplay.rewrite(next, confirmedLayoutID: "ru", currentLayoutID: { "ru" },
            translate: { _, shift, caps in XCTAssertTrue(shift); XCTAssertTrue(caps); return "е" }))
        XCTAssertEqual(next.flags, [.maskShift, .maskAlphaShift])
        next.type = .keyUp
        XCTAssertFalse(HeldKeyReplay.rewrite(next, confirmedLayoutID: "ru", currentLayoutID: { "ru" },
            translate: { _, _, _ in XCTFail("Must not alter key-up"); return "Е" }))
    }

    func testLateSourceAcknowledgementIsObservedWhenDelayedKeyActuallyForwards() throws {
        var clock: TimeInterval = 0
        var requested = false
        let outcome = LayoutSelectionCommit.requestAndObserve(targetID: "ru",
            currentID: { clock >= 0.025 ? "ru" : "en" },
            request: { requested = true; return true }, now: { clock }, pause: { clock += $0 })
        XCTAssertTrue(requested)
        XCTAssertEqual(outcome, .unconfirmed)
        let fence = InputEventFence()
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        let timestamp = DispatchTime.now().uptimeNanoseconds
        fence.finish(lease, replayLayoutID: nil)
        let admission = fence.enterPhysicalEvent(eventTimestamp: timestamp)
        defer { fence.leavePhysicalEvent() }
        XCTAssertTrue(admission.needsSourceRefresh)
        XCTAssertNil(admission.replayLayoutID)
        clock = 0.025
        let next = event()
        var sourceReads = 0
        let sourceID = HeldKeyReplay.refreshUsingObservedSource(next, observeSource: {
            sourceReads += 1
            return clock >= 0.025 ? "ru" : "en"
        }, translate: { id, _, _, _ in id == "ru" ? "е" : "t" })
        XCTAssertEqual(sourceID, "ru")
        XCTAssertEqual(text(next), "е")
        XCTAssertEqual(sourceReads, 1)
    }

    func testObservedSourceAndPayloadStayTogetherWhenGlobalSourceLaterChanges() {
        let next = event()
        var globalSource = "ru"
        let observed = HeldKeyReplay.refreshUsingObservedSource(next, observeSource: { globalSource },
            translate: { id, _, _, _ in globalSource = "en"; return id == "ru" ? "е" : "t" })
        XCTAssertEqual(globalSource, "en")
        XCTAssertEqual(observed, "ru")
        XCTAssertEqual(text(next), "е")
    }

    func testPostLeaseKeyStillRefreshesWhenSourceAcknowledgementWasLate() {
        var transition = InputSourceTransitionTracker()
        transition.noteUnconfirmed(targetID: "ru", startingAt: 20)
        transition.recordCompletedWindow(start: 1, end: 20)
        XCTAssertTrue(transition.needsRefresh(eventTimestamp: 22))
        transition.observe(sourceID: "ru", at: 25)
        XCTAssertFalse(transition.hasPending)
        XCTAssertTrue(transition.needsRefresh(eventTimestamp: 22))
        let next = event()
        let observed = HeldKeyReplay.refreshUsingObservedSource(next, observeSource: { "ru" },
            translate: { id, _, _, _ in id == "ru" ? "е" : "t" })
        XCTAssertEqual(observed, "ru")
        XCTAssertEqual(text(next), "е")
    }
}
