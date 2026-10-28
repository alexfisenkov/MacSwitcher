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
    let eventUTF16Length: Int
    let atBoundary: Bool

    func isCurrent(processID: Int32?, revision: UInt64, generation: UInt64) -> Bool {
        self.processID > 0 && self.processID == processID
            && inputRevision == revision && self.generation == generation
    }
}

/// Only a bounded window of text typed in this focus session is retained in RAM.
/// Earlier short tokens survive the next word so `f привет` can become `а привет`.
struct PredictionInputBuffer: Sendable {
    /// Storage budget in UTF-16 units; one grapheme can contain many scalars.
    static let maximumCharacters = 384
    private(set) var text = ""
    private(set) var processID: Int32?
    private(set) var sessionID: UInt64 = 0
    private(set) var cumulativeUTF16Offset = 0
    private var eventUTF16Length = 0
    private var discardTokenUntilBoundary = false

    mutating func reset() {
        text = ""; processID = nil; sessionID &+= 1; cumulativeUTF16Offset = 0; eventUTF16Length = 0
        discardTokenUntilBoundary = false
    }

    private mutating func trimToBudget() {
        while text.utf16.count > Self.maximumCharacters {
            // Keep only complete tokens. A truncated current token cannot be scored.
            guard let firstSpace = text.firstIndex(where: \.isWhitespace) else {
                text = ""
                discardTokenUntilBoundary = true
                return
            }
            text.removeSubrange(text.startIndex...firstSpace)
        }
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
        eventUTF16Length = characters.utf16.count
        self.processID = processID
        if discardTokenUntilBoundary {
            guard let boundary = characters.firstIndex(where: \.isWhitespace) else { return }
            discardTokenUntilBoundary = false
            text = String(characters[boundary...])
        } else {
            text.append(characters)
        }
        trimToBudget()
    }

    mutating func replaceSuffix(original: String, replacement: String) -> Bool {
        guard !discardTokenUntilBoundary, !original.isEmpty, text.hasSuffix(original),
              replacement.utf16.count <= Self.maximumCharacters,
              cumulativeUTF16Offset >= original.utf16.count else { return false }
        let (offset, overflow) = (cumulativeUTF16Offset - original.utf16.count)
            .addingReportingOverflow(replacement.utf16.count)
        guard !overflow else { reset(); return false }
        cumulativeUTF16Offset = offset
        text.removeLast(original.count)
        text.append(replacement)
        trimToBudget()
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
        guard suffix.utf16.count <= 192 else { return nil }
        let preceding = text[..<start].split(whereSeparator: \.isWhitespace).suffix(4).map(String.init)
        return PredictionSnapshot(suffix: suffix, precedingWords: preceding,
            sourceLayoutID: sourceLayoutID, processID: processID,
            inputRevision: inputRevision, generation: generation,
            sessionID: sessionID,
            cumulativeUTF16Offset: cumulativeUTF16Offset,
            eventUTF16Length: eventUTF16Length,
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

/// A first-event observation is not an acknowledgement that its glyph has
/// reached the target process. Resolve only against the same original field,
/// a current snapshot and the exact rendered suffix.
struct PredictionPendingCaretAnchor: Sendable {
    private let sessionID: UInt64
    private let candidates: [PredictionCaretAnchor]
    private var cancelled = false
    private(set) var resolved: PredictionCaretAnchor?

    init?(sessionID: UInt64, caretUTF16Location: Int, inputUTF16Offset: Int, eventUTF16Length: Int) {
        guard caretUTF16Location >= 0, eventUTF16Length > 0,
              inputUTF16Offset >= eventUTF16Length else { return nil }
        self.sessionID = sessionID
        candidates = [
            PredictionCaretAnchor(caretUTF16Location: caretUTF16Location,
                inputUTF16Offset: inputUTF16Offset),
            PredictionCaretAnchor(caretUTF16Location: caretUTF16Location,
                inputUTF16Offset: inputUTF16Offset - eventUTF16Length)
        ]
    }

    mutating func resolve(sessionID: UInt64, location: Int, selectionLength: Int,
                          cumulativeOffset: Int, sameField: Bool, snapshotIsCurrent: Bool,
                          suffixMatches: Bool) -> PredictionCaretAnchor? {
        guard !cancelled else { return nil }
        guard self.sessionID == sessionID, sameField else { cancelled = true; return nil }
        guard snapshotIsCurrent, suffixMatches else { return nil }
        if let resolved {
            return resolved.permits(location: location, selectionLength: selectionLength,
                cumulativeOffset: cumulativeOffset) ? resolved : nil
        }
        guard let candidate = candidates.first(where: {
            $0.permits(location: location, selectionLength: selectionLength, cumulativeOffset: cumulativeOffset)
        }) else { return nil }
        resolved = candidate
        return candidate
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
