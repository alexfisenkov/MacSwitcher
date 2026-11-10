import XCTest
@testable import RuSwitcher

final class GenericShellEditorProtocolTests: XCTestCase {
    private func snapshot(buffer: String = "ghbdtn", nonce: String = "D7607DCE-E311-498A-8305-D41E12E9CBA8.1")
        -> GenericShellEditorSnapshot {
        GenericShellEditorSnapshot(sessionPID: 42, tty: "/dev/ttys001", lineNonce: nonce,
            buffer: buffer, cursor: buffer.count, mark: 0, regionActive: 0)
    }

    func testWireRoundTripsUnicodeQuotesAndNewlinesWithoutShellEvaluation() {
        let original = "🙂 'ghbdtn'\nНЕ_ИСПОЛНЯТЬ"
        let before = snapshot(buffer: original)
        let id = UUID()
        let encoded = GenericShellEditorWire.encode(original)
        let decoded = GenericShellEditorWire.decodeSnapshot(
            "S \(id.uuidString) \(before.lineNonce) \(before.cursor) 0 0 \(encoded)",
            expectedRequestID: id, sessionPID: 42, tty: before.tty)
        XCTAssertEqual(decoded, before)
        let proposal = GenericShellEditorProposal(expected: before,
            replacementBuffer: "🙂 'привет'\nНЕ_ИСПОЛНЯТЬ",
            replacementCursor: "🙂 'привет'\nНЕ_ИСПОЛНЯТЬ".count, requestID: id)
        XCTAssertNotNil(GenericShellEditorWire.editLine(proposal))
    }

    func testInvalidNonceOffsetsAndOversizeRefuse() {
        let id = UUID()
        XCTAssertNil(GenericShellEditorWire.decodeSnapshot("S \(id.uuidString) 1 6 0 0 Z2hiZHRu",
            expectedRequestID: id, sessionPID: 42, tty: "/dev/ttys001"))
        XCTAssertNil(GenericShellEditorWire.decodeSnapshot("S \(id.uuidString) \(snapshot().lineNonce) 99 0 0 Z2hiZHRu",
            expectedRequestID: id, sessionPID: 42, tty: "/dev/ttys001"))
        XCTAssertNil(GenericShellEditorWire.decode("%%%"))
        XCTAssertFalse(GenericShellEditorWire.validBuffer(String(repeating: "а", count: 32769)))
        XCTAssertNil(GenericShellEditorWire.editLine(.init(expected: snapshot(nonce: "1"),
            replacementBuffer: "привет", replacementCursor: 6, requestID: id)))
    }
}
