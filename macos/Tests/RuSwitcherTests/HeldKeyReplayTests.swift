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
        for flags in [CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn] {
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

    func testPreLeaseQueuedKeyUsesReceiptAfterLastKnownForwardedTimestamp() throws {
        let fence = InputEventFence()
        let lastForwarded = fence.enterPhysicalEvent(eventTimestamp: DispatchTime.now().uptimeNanoseconds)
        fence.leavePhysicalEvent(lastForwarded)
        let next = event()
        let beforeLease = DispatchTime.now().uptimeNanoseconds
        next.timestamp = beforeLease
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        fence.finish(lease, replayLayoutID: "ru")
        let admission = fence.enterPhysicalEvent(eventTimestamp: beforeLease)
        defer { fence.leavePhysicalEvent() }
        XCTAssertFalse(admission.wasHeld)
        XCTAssertTrue(admission.needsSourceRefresh)
        var reads = 0
        let source = HeldKeyReplay.refreshForForwarding(next,
            needsSourceRefresh: admission.needsSourceRefresh, remoteDesktopMode: false,
            observeSource: { reads += 1; return "ru" },
            translate: { source, _, _, _ in source == "ru" ? "е" : "t" })
        XCTAssertEqual(source, "ru")
        XCTAssertEqual(text(next), "е")
        XCTAssertEqual(reads, 1)
    }

    func testIdleASCIIReplacementPayloadIsNotReinterpretedFromPhysicalKeyCode() {
        // A remapper/software keyboard intentionally emitted ASCII t on the a key.
        let next = event(key: 0)
        XCTAssertNil(HeldKeyReplay.refreshForForwarding(next, needsSourceRefresh: false, remoteDesktopMode: false,
            observeSource: { XCTFail("No correction window authorizes source refresh"); return "en" },
            translate: { _, _, _, _ in XCTFail("Preserve intentional payload"); return "a" }))
        XCTAssertEqual(text(next), "t")
    }

    func testRemappedPayloadOutsideOldReceiptRemainsUnchanged() throws {
        let fence = InputEventFence()
        let prior = fence.enterPhysicalEvent(eventTimestamp: DispatchTime.now().uptimeNanoseconds)
        fence.leavePhysicalEvent(prior)
        let lease = try XCTUnwrap(fence.begin(processID: 42))
        fence.finish(lease, replayLayoutID: "ru")
        let next = event(key: 0)
        next.timestamp = DispatchTime.now().uptimeNanoseconds
        let admission = fence.enterPhysicalEvent(eventTimestamp: next.timestamp)
        defer { fence.leavePhysicalEvent(admission) }
        XCTAssertFalse(admission.needsSourceRefresh)
        XCTAssertNil(HeldKeyReplay.refreshForForwarding(next,
            needsSourceRefresh: admission.needsSourceRefresh, remoteDesktopMode: false,
            observeSource: { XCTFail("Completed old window must not authorize this event"); return "ru" },
            translate: { _, _, _, _ in XCTFail("Keep remapped payload"); return "ф" }))
        XCTAssertEqual(text(next), "t")
    }

    func testForwardingPreservesRemoteUnicodeAndInputWithoutTransitionReceipt() {
        for (receipt, remote) in [(true, true), (false, true), (false, false)] {
            let next = event()
            XCTAssertNil(HeldKeyReplay.refreshForForwarding(next, needsSourceRefresh: receipt, remoteDesktopMode: remote,
                observeSource: { XCTFail("Ineligible input must not read or decode a source"); return "ru" },
                translate: { _, _, _, _ in XCTFail("Preserve forwarded input"); return "е" }))
            XCTAssertEqual(text(next), "t")
        }
    }

    func testEmptyComposedAndUnsupportedPayloadsCannotInventPrintableText() {
        for original in ["", "é", "e\u{301}", "😀", "ab", "\u{0483}", "\n"] {
            let next = event()
            let units = Array(original.utf16)
            units.withUnsafeBufferPointer {
                next.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
            }
            XCTAssertFalse(HeldKeyReplay.rewrite(next, confirmedLayoutID: "ru", currentLayoutID: { "ru" },
                translate: { _, _, _ in XCTFail("Unsupported payload must not be decoded"); return "е" }))
            XCTAssertEqual(text(next), original)
        }
    }

    func testMissingDeadKeyOrUnsupportedTranslationPreservesOriginalPayload() {
        for translated: Character? in [nil, "é", "e\u{301}", "😀", "\u{0483}", "\n"] {
            let next = event()
            XCTAssertFalse(HeldKeyReplay.rewrite(next, confirmedLayoutID: "ru", currentLayoutID: { "ru" },
                translate: { _, _, _ in translated }))
            XCTAssertEqual(text(next), "t")
        }
    }
}
