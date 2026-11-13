import Foundation

/// Pure range checks before a shell-owned CAS. ZLE positions count Unicode
/// scalars; Swift grapheme-cluster `String.count` is not used for offsets.
enum GenericShellEditorPlanner {
    enum ExternalSelection { case collapsed, selected, unknown }

    static func selectedRange(_ snapshot: GenericShellEditorSnapshot,
                              externalSelection: ExternalSelection) -> Range<Int>? {
        guard case .collapsed = externalSelection, snapshot.regionActive == 1,
              snapshot.cursor != snapshot.mark else { return nil }
        return min(snapshot.cursor, snapshot.mark)..<max(snapshot.cursor, snapshot.mark)
    }

    static func exactWordRange(_ snapshot: GenericShellEditorSnapshot, word: String,
                               trailingSpaces: Int, externalSelection: ExternalSelection) -> Range<Int>? {
        guard case .collapsed = externalSelection, snapshot.regionActive == 0,
              !word.isEmpty, word.unicodeScalars.count <= 24,
              trailingSpaces >= 0, trailingSpaces <= 16 else { return nil }
        let scalars = Array(snapshot.buffer.unicodeScalars)
        let wordScalars = Array(word.unicodeScalars)
        guard snapshot.cursor >= wordScalars.count + trailingSpaces,
              snapshot.cursor <= scalars.count else { return nil }
        let end = snapshot.cursor - trailingSpaces
        let start = end - wordScalars.count
        guard scalars[start..<end].elementsEqual(wordScalars),
              scalars[end..<snapshot.cursor].allSatisfy({ $0 == " " }),
              (start == 0 || !CharacterSet.letters.contains(scalars[start - 1])) else { return nil }
        return start..<end
    }

    static func observedLastWordRange(_ snapshot: GenericShellEditorSnapshot,
                                      externalSelection: ExternalSelection) -> Range<Int>? {
        guard case .collapsed = externalSelection, snapshot.regionActive == 0 else { return nil }
        let scalars = Array(snapshot.buffer.unicodeScalars)
        guard snapshot.cursor > 0, snapshot.cursor <= scalars.count else { return nil }
        var end = snapshot.cursor
        while end > 0 && scalars[end - 1] == " " && snapshot.cursor - end < 16 { end -= 1 }
        guard end > 0, scalars[end - 1] != " " else { return nil }
        var start = end
        while start > 0 && CharacterSet.letters.contains(scalars[start - 1]) && end - start < 24 {
            start -= 1
        }
        guard start < end, end - start <= 24,
              start == 0 || !CharacterSet.letters.contains(scalars[start - 1]) else { return nil }
        return start..<end
    }

    static func wholePrefixRange(_ snapshot: GenericShellEditorSnapshot,
                                 externalSelection: ExternalSelection) -> Range<Int>? {
        guard case .collapsed = externalSelection, snapshot.regionActive == 0,
              snapshot.cursor > 0, snapshot.cursor <= snapshot.buffer.unicodeScalars.count else { return nil }
        return 0..<snapshot.cursor
    }

    static func proposal(snapshot: GenericShellEditorSnapshot, range: Range<Int>,
                         replacement: String, requestID: UUID = UUID(),
                         collapseToReplacementEnd: Bool? = nil) -> GenericShellEditorProposal? {
        let scalars = Array(snapshot.buffer.unicodeScalars)
        guard range.lowerBound >= 0, range.upperBound <= scalars.count,
              range.lowerBound < range.upperBound, !replacement.isEmpty else { return nil }
        let original = String(String.UnicodeScalarView(scalars[range]))
        guard original != replacement else { return nil }
        let candidate = String(String.UnicodeScalarView(scalars[..<range.lowerBound]))
            + replacement + String(String.UnicodeScalarView(scalars[range.upperBound...]))
        guard GenericShellEditorWire.validBuffer(candidate) else { return nil }
        let collapse = collapseToReplacementEnd ?? (snapshot.regionActive != 0)
        let cursor = !collapse
            ? snapshot.cursor + replacement.unicodeScalars.count - range.count
            : range.lowerBound + replacement.unicodeScalars.count
        return GenericShellEditorProposal(expected: snapshot,
            replacementBuffer: candidate, replacementCursor: cursor, requestID: requestID)
    }
}
