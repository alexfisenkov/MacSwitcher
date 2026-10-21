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

}
