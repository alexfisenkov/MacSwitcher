import Foundation

/// Shell-owned editable line. Offsets are ZLE character offsets, not UTF-8 bytes
/// or AX UTF-16 offsets. No process command line or environment contains text.
struct GenericShellEditorSnapshot: Equatable, Sendable {
    let sessionPID: Int32
    let tty: String
    let lineNonce: String
    let buffer: String
    let cursor: Int
    let mark: Int
    let regionActive: Int
}

struct GenericShellEditorProposal: Equatable, Sendable {
    let expected: GenericShellEditorSnapshot
    let replacementBuffer: String
    let replacementCursor: Int
    let requestID: UUID
}

struct GenericShellPreparedHandle: Equatable, Sendable {
    let sessionPID: Int32
    let tty: String
    let lineNonce: String
}

enum GenericShellEditorOutcome: Equatable, Sendable {
    case confirmed(GenericShellEditorSnapshot)
    case refused(GenericShellEditorSnapshot?)
    /// Delivery may have happened. Call `query` and reconcile; never resend it.
    case uncertain
}

/// The host provides this only after proving the focused tab's shell PID and
/// TTY. Terminal family names are deliberately absent from this contract.
protocol GenericShellEditorFocusProof {
    func permits(sessionPID: Int32, tty: String) -> Bool
}

enum GenericShellEditorWire {
    static let maxBufferUTF8 = 64 * 1024
    static let maxLineUTF8 = 2 * (((maxBufferUTF8 + 2) / 3) * 4) + 512

    static func validBuffer(_ text: String) -> Bool {
        text.utf8.count <= maxBufferUTF8 && !text.utf8.contains(0)
    }

    static func encode(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    static func decode(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), data.count <= maxBufferUTF8,
              let text = String(data: data, encoding: .utf8), validBuffer(text) else { return nil }
        return text
    }

    static func boundedNonnegative(_ raw: String, maximum: Int) -> Int? {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(raw), value <= maximum else { return nil }
        return value
    }

    static func validNonce(_ raw: String) -> Bool {
        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 2 && UUID(uuidString: String(pieces[0])) != nil
            && boundedNonnegative(String(pieces[1]), maximum: Int.max) != nil
    }

    static func decodeSnapshot(_ line: String, expectedRequestID: UUID, sessionPID: Int32,
                               tty: String) -> GenericShellEditorSnapshot? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7, parts[0] == "S", parts[1] == expectedRequestID.uuidString,
              validNonce(parts[2]),
              let buffer = decode(parts[6]),
              let cursor = boundedNonnegative(parts[3], maximum: buffer.unicodeScalars.count),
              let mark = boundedNonnegative(parts[4], maximum: buffer.unicodeScalars.count),
              let region = boundedNonnegative(parts[5], maximum: 2) else { return nil }
        return GenericShellEditorSnapshot(sessionPID: sessionPID, tty: tty,
            lineNonce: parts[2], buffer: buffer, cursor: cursor, mark: mark, regionActive: region)
    }

    static func editLine(_ proposal: GenericShellEditorProposal) -> String? {
        let before = proposal.expected
        guard validBuffer(before.buffer), validBuffer(proposal.replacementBuffer),
              proposal.replacementBuffer != before.buffer,
              before.cursor >= 0, before.cursor <= before.buffer.unicodeScalars.count,
              before.mark >= 0, before.mark <= before.buffer.unicodeScalars.count,
              (0...2).contains(before.regionActive),
              proposal.replacementCursor >= 0,
              proposal.replacementCursor <= proposal.replacementBuffer.unicodeScalars.count else { return nil }
        guard validNonce(before.lineNonce) else { return nil }
        return ["E", proposal.requestID.uuidString, before.lineNonce,
                String(before.cursor), String(before.mark), String(before.regionActive),
                encode(before.buffer), encode(proposal.replacementBuffer),
                String(proposal.replacementCursor)].joined(separator: " ") + "\n"
    }
}
