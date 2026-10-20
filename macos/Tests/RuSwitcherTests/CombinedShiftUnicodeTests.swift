import CoreGraphics
import XCTest
@testable import RuSwitcher

final class CombinedShiftUnicodeTests: XCTestCase {
    private func verify(_ text: String, expectedSizes: [Int]? = nil) throws {
        let packets = CombinedShiftUnicode.chunks(text)
        if let expectedSizes { XCTAssertEqual(packets.map(\.count), expectedSizes) }
        XCTAssertEqual(packets.flatMap { $0 }, Array(text.utf16))
        XCTAssertEqual(String(decoding: packets.flatMap { $0 }, as: UTF16.self), text)
        for packet in packets {
            XCTAssertFalse(packet.isEmpty)
            XCTAssertLessThanOrEqual(packet.count, 20)
            XCTAssertFalse((0xDC00...0xDFFF).contains(packet.first!))
            XCTAssertFalse((0xD800...0xDBFF).contains(packet.last!))
            let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
            for down in [true, false] {
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down))
                packet.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                XCTAssertTrue(CombinedShiftUnicode.payloadMatches(event, expected: packet))
            }
        }
    }

    func testTwentyOneAndFiftyUnitWordsRemainComplete() throws {
        try verify(String(repeating: "a", count: 21), expectedSizes: [20, 1])
        try verify(String(repeating: "б", count: 50), expectedSizes: [20, 20, 10])
    }

    func testEmojiAroundPacketBoundariesRemainLosslessAndEventPayloadsRoundTrip() throws {
        for prefix in [18, 19, 20] {
            try verify(String(repeating: "a", count: prefix) + "😀" + String(repeating: "б", count: 29))
        }
        try verify(String(repeating: "😀", count: 15), expectedSizes: [20, 10])
    }
}
