import Foundation

/// A short-lived value, never persisted or logged. Source identity belongs to the
/// actual character event, rather than the source selected later by a Shift tap.
struct PredictionSnapshot: Sendable, Equatable {
    let suffix: String
    let precedingWords: [String]
    let sourceLayoutID: String
    let processID: Int32
    let inputRevision: UInt64
    let generation: UInt64
    let sessionID: UInt64
    let cumulativeUTF16Offset: Int
    let atBoundary: Bool

    func isCurrent(processID: Int32?, revision: UInt64, generation: UInt64) -> Bool {
        self.processID > 0 && self.processID == processID
            && inputRevision == revision && self.generation == generation
    }
}

/// Only a bounded window of text typed in this focus session is retained in RAM.
/// Earlier short tokens survive the next word so `f привет` can become `а привет`.
struct PredictionInputBuffer: Sendable {
    static let maximumCharacters = 384
    private(set) var text = ""
    private(set) var processID: Int32?
    private(set) var sessionID: UInt64 = 0
    private(set) var cumulativeUTF16Offset = 0

    mutating func reset() {
        text = ""; processID = nil; sessionID &+= 1; cumulativeUTF16Offset = 0
    }

    mutating func append(_ characters: String, processID: Int32) {
        guard processID > 0, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            reset(); return
        }
        if self.processID != processID { reset() }
        let (offset, overflow) = cumulativeUTF16Offset.addingReportingOverflow(characters.utf16.count)
        guard !overflow else { reset(); return }
        cumulativeUTF16Offset = offset
        self.processID = processID
        text.append(characters)
        if text.count > Self.maximumCharacters {
            text = String(text.suffix(Self.maximumCharacters))
            // Do not present a truncated token as a complete dictionary word.
            if let firstSpace = text.firstIndex(where: \.isWhitespace) {
                text.removeSubrange(text.startIndex...firstSpace)
            } else { text = "" }
        }
    }

    mutating func replaceSuffix(original: String, replacement: String) -> Bool {
        guard !original.isEmpty, text.hasSuffix(original),
              replacement.count <= Self.maximumCharacters,
              cumulativeUTF16Offset >= original.utf16.count else { return false }
        let (offset, overflow) = (cumulativeUTF16Offset - original.utf16.count)
            .addingReportingOverflow(replacement.utf16.count)
        guard !overflow else { reset(); return false }
        cumulativeUTF16Offset = offset
        text.removeLast(original.count)
        text.append(replacement)
        if text.count > Self.maximumCharacters { text = String(text.suffix(Self.maximumCharacters)) }
        return true
    }

    func snapshot(sourceLayoutID: String, inputRevision: UInt64, generation: UInt64) -> PredictionSnapshot? {
        guard let processID, !sourceLayoutID.isEmpty, !text.isEmpty else { return nil }
        var starts: [String.Index] = []
        var previousWasSpace = true
        for index in text.indices {
            let isSpace = text[index].isWhitespace
            if previousWasSpace && !isSpace { starts.append(index) }
            previousWasSpace = isSpace
        }
        guard !starts.isEmpty else { return nil }
        let start = starts[max(0, starts.count - 2)]
        let suffix = String(text[start...])
        guard suffix.count <= 192 else { return nil }
        let preceding = text[..<start].split(whereSeparator: \.isWhitespace).suffix(4).map(String.init)
        return PredictionSnapshot(suffix: suffix, precedingWords: preceding,
            sourceLayoutID: sourceLayoutID, processID: processID,
            inputRevision: inputRevision, generation: generation,
            sessionID: sessionID,
            cumulativeUTF16Offset: cumulativeUTF16Offset,
            atBoundary: text.last?.isWhitespace == true)
    }
}

enum PredictionFocusAnchorPolicy {
    static func permits(originalSession: UInt64?, currentSession: UInt64,
                        capturedOriginalField: Bool, sameField: Bool) -> Bool {
        originalSession == currentSession && capturedOriginalField && sameField
    }
}

/// Event-linked caret arithmetic detects a programmatic jump to another identical
/// occurrence in the same field without reading AX for every character.
struct PredictionCaretAnchor: Sendable {
    let caretUTF16Location: Int
    let inputUTF16Offset: Int

    func expectedLocation(for cumulativeOffset: Int) -> Int? {
        guard caretUTF16Location >= 0, inputUTF16Offset >= 0, cumulativeOffset >= 0 else { return nil }
        let (delta, differenceOverflow) = cumulativeOffset.subtractingReportingOverflow(inputUTF16Offset)
        let (location, locationOverflow) = caretUTF16Location.addingReportingOverflow(delta)
        guard !differenceOverflow, !locationOverflow, location >= 0 else { return nil }
        return location
    }

    func permits(location: Int, selectionLength: Int, cumulativeOffset: Int) -> Bool {
        selectionLength == 0 && expectedLocation(for: cumulativeOffset) == location
    }
}

/// Leave an unchanged neighbour (including emoji or an acronym) outside the edit.
/// Only the shared prefix is trimmed: the result is still a suffix at the caret.
struct PredictionSuffixEdit: Sendable, Equatable {
    let original: String
    let replacement: String

    init?(original: String, replacement: String) {
        let common = zip(original, replacement).prefix(while: { $0 == $1 }).count
        self.original = String(original.dropFirst(common))
        self.replacement = String(replacement.dropFirst(common))
        guard !self.original.isEmpty, !self.replacement.isEmpty,
              self.original != self.replacement else { return nil }
    }
}
