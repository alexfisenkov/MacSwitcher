import CoreGraphics
import XCTest
@testable import RuSwitcher

final class NativeSelectedEventTransportTests: XCTestCase {
    @MainActor
    func testThousandUnitSelectionPacketRoundTripsEntirePreparedPayloadWithoutPosting() throws {
        let replacement = String(repeating: "б", count: 1000)
        let transport = try XCTUnwrap(NativeSelectedTextEventTransport(replacement: replacement))
        XCTAssertEqual(transport.events.count, 2)
        XCTAssertEqual(transport.events.map(\.type), [.keyDown, .keyUp])
        for event in transport.events {
            XCTAssertTrue(CombinedShiftUnicode.payloadMatches(event, expected: Array(replacement.utf16)))
            XCTAssertTrue(event.flags.isEmpty)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), kRuSwitcherEventMarker)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventAutorepeat), 0)
        }
    }

    @MainActor
    func testPreparedSelectionPayloadPreservesNewlinesAndEmojiAndRejectsOversize() throws {
        let replacement = "строка\n😀 e\u{301}\t🧑🏽‍💻"
        let transport = try XCTUnwrap(NativeSelectedTextEventTransport(replacement: replacement))
        for event in transport.events {
            XCTAssertTrue(CombinedShiftUnicode.payloadMatches(event, expected: Array(replacement.utf16)))
        }
        XCTAssertNil(NativeSelectedTextEventTransport(replacement: ""))
        XCTAssertNil(NativeSelectedTextEventTransport(replacement: String(repeating: "б", count: 8193)))
    }
    @MainActor
    func testSelectionPayloadAt8192UTF16UnitLimitRoundTripsSurrogatePairs() throws {
        let replacement = String(repeating: "😀", count: 4096)
        XCTAssertEqual(replacement.utf16.count, 8192)
        let transport = try XCTUnwrap(NativeSelectedTextEventTransport(replacement: replacement))
        for event in transport.events {
            XCTAssertTrue(CombinedShiftUnicode.payloadMatches(event, expected: Array(replacement.utf16)))
        }
    }

    @MainActor
    func testOrdinaryPreparedPhasesSeparateSelectionFromTextAndReuseCaretCleanup() throws {
        let transport = try XCTUnwrap(NativeAutoEventTransport(original: "ghbdtn", replacement: "привет"))
        XCTAssertEqual(transport.preparedSelection.operations, Array(repeating: .selectPreviousCharacter, count: 6))
        XCTAssertEqual(transport.preparedSelection.events.count, 12)
        XCTAssertEqual(transport.preparedReplacement.operations, [.insertReplacement, .selectPreviousCharacter, .right])
        XCTAssertEqual(transport.preparedReplacement.events.count, 6)
        XCTAssertEqual(transport.preparedCancellation.operations, [.selectPreviousCharacter, .right])
        for (index, event) in transport.preparedSelection.events.enumerated() {
            XCTAssertEqual(event.type, index.isMultiple(of: 2) ? .keyDown : .keyUp)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), kRuSwitcherEventMarker)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventAutorepeat), 0)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 123)
            XCTAssertEqual(event.flags, .maskShift)
        }
        for (index, event) in transport.preparedReplacement.events.enumerated() {
            XCTAssertEqual(event.type, index.isMultiple(of: 2) ? .keyDown : .keyUp)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), kRuSwitcherEventMarker)
            if index < 2 {
                XCTAssertTrue(event.flags.isEmpty)
                XCTAssertTrue(CombinedShiftUnicode.payloadMatches(event, expected: Array("привет".utf16)))
            } else {
                XCTAssertTrue(event === transport.preparedCancellation.events[index - 2])
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), index < 4 ? 123 : 124)
                XCTAssertEqual(event.flags, index < 4 ? .maskShift : [])
            }
        }
    }

    @MainActor
    func testMaximumOrdinaryPhasesAllocateExactlyFiftyFourDistinctEvents() throws {
        let original = String(repeating: "a", count: 24)
        let replacement = String(repeating: "б", count: 24)
        let transport = try XCTUnwrap(NativeAutoEventTransport(original: original, replacement: replacement))
        XCTAssertEqual(transport.preparedSelection.events.count + transport.preparedReplacement.events.count,
            NativeFieldBatchPoster.maximumEvents)
        XCTAssertNil(NativeAutoEventTransport(original: original + "a", replacement: replacement + "б"))
        XCTAssertNil(NativeAutoEventTransport(original: "", replacement: ""))
        XCTAssertNil(NativeAutoEventTransport(original: "ghbd", replacement: "привет"))
        XCTAssertNil(NativeAutoEventTransport(original: "😀", replacement: "а"))
    }

}
