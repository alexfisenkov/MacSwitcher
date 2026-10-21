import Foundation

/// A bounded, whole-field read. Equality deliberately compares UTF-16 units:
/// Swift's canonically equivalent String equality is insufficient for recovery.
struct NativeFieldObservation: Equatable {
    let text: String
    let caretUTF16Location: Int
    let selectionLength: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.caretUTF16Location == rhs.caretUTF16Location
            && lhs.selectionLength == rhs.selectionLength
            && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }
}

enum NativeFieldEditOperation: Equatable {
    case insertReplacement, left, backspace, right
}

enum NativeFieldEditRefusal: Error, Equatable {
    case readOnly, invalidEdit, fieldTooLarge, invalidRange, originalMismatch, unsupportedDirection
}

struct NativeFieldEditStep {
    let operation: NativeFieldEditOperation
    let expectedBefore: NativeFieldObservation
    let expectedAfter: NativeFieldObservation
}

/// Immutable insert-first states. Every movement and every single deletion has
/// its own exact whole-field/caret acknowledgement, including both neighbours.
struct NativeFieldEditPlan {
    static let maximumFieldUnits = 32_768
    static let maximumEditUnits = 24
    static let maximumSelectedReplacementUnits = 8_192

    let originalSnapshot: NativeFieldObservation
    let resultSnapshot: NativeFieldObservation
    let steps: [NativeFieldEditStep]

    // ICU covers supplementary RTL scripts as well as Hebrew/Arabic. Refuse if
    // the system cannot compile this Unicode-property expression.
    private static let unsafeDirection = try? NSRegularExpression(
        pattern: "[\\p{bc=R}\\p{bc=AL}\\p{bc=AN}\\p{Bidi_Control}]")

    static func make(original: String, replacement: String, start: Int,
                     snapshot: NativeFieldObservation, isEditable: Bool = true)
        -> Result<Self, NativeFieldEditRefusal> {
        guard isEditable else { return .failure(.readOnly) }
        guard isSimpleText(original), isSimpleText(replacement),
              !original.utf16.elementsEqual(replacement.utf16),
              original.utf16.count == replacement.utf16.count else { return .failure(.invalidEdit) }
        let count = original.utf16.count
        let whole = Array(snapshot.text.utf16)
        // The insertion's duplicate must fit too, not only the original value.
        guard whole.count <= maximumFieldUnits - count else { return .failure(.fieldTooLarge) }
        guard start >= 0, start <= whole.count, count <= whole.count - start,
              snapshot.selectionLength == 0,
              snapshot.caretUTF16Location == start + count else { return .failure(.invalidRange) }
        guard whole[start..<(start + count)].elementsEqual(original.utf16) else { return .failure(.originalMismatch) }
        guard let unsafeDirection,
              unsafeDirection.firstMatch(in: snapshot.text,
                  range: NSRange(location: 0, length: whole.count)) == nil else { return .failure(.unsupportedDirection) }

        let prefixUnits = Array(whole[..<start])
        let suffixUnits = Array(whole[(start + count)...])
        guard isWellFormedUTF16(whole), isWellFormedUTF16(prefixUnits), isWellFormedUTF16(suffixUnits) else {
            return .failure(.invalidRange)
        }
        let prefix = String(decoding: prefixUnits, as: UTF16.self)
        let suffix = String(decoding: suffixUnits, as: UTF16.self)
        var current = snapshot
        var steps: [NativeFieldEditStep] = []
        steps.reserveCapacity(1 + 3 * count)
        func append(_ operation: NativeFieldEditOperation, text: String, caret: Int) {
            let after = NativeFieldObservation(text: text, caretUTF16Location: caret, selectionLength: 0)
            steps.append(NativeFieldEditStep(operation: operation, expectedBefore: current, expectedAfter: after))
            current = after
        }
        let duplicate = prefix + original + replacement + suffix
        append(.insertReplacement, text: duplicate, caret: start + 2 * count)
        for offset in 1...count { append(.left, text: duplicate, caret: start + 2 * count - offset) }
        let originalUnits = Array(original.utf16)
        for removed in 1...count {
            let remaining = String(decoding: originalUnits.prefix(count - removed), as: UTF16.self)
            append(.backspace, text: prefix + remaining + replacement + suffix, caret: start + count - removed)
        }
        let result = prefix + replacement + suffix
        for offset in 1...count { append(.right, text: result, caret: start + offset) }
        return .success(Self(originalSnapshot: snapshot, resultSnapshot: current, steps: steps))
    }

    /// Replace only an already existing user selection. The single native
    /// Unicode pair replaces that selection; no navigation/deletion is planned.
    static func makeSelected(original: String, replacement: String, start: Int,
                             snapshot: NativeFieldObservation, isEditable: Bool = true)
        -> Result<Self, NativeFieldEditRefusal> {
        guard isEditable else { return .failure(.readOnly) }
        let originalCount = original.utf16.count
        let replacementCount = replacement.utf16.count
        guard originalCount > 0, replacementCount > 0,
              replacementCount <= maximumSelectedReplacementUnits,
              !original.utf16.elementsEqual(replacement.utf16) else { return .failure(.invalidEdit) }
        let wholeCount = snapshot.text.utf16.count
        guard wholeCount <= maximumFieldUnits,
              originalCount <= wholeCount else { return .failure(.fieldTooLarge) }
        guard start >= 0, start <= wholeCount, originalCount <= wholeCount - start,
              snapshot.caretUTF16Location == start,
              snapshot.selectionLength == originalCount else { return .failure(.invalidRange) }
        guard wholeCount - originalCount <= maximumFieldUnits - replacementCount else {
            return .failure(.fieldTooLarge)
        }
        let whole = Array(snapshot.text.utf16)
        guard whole[start..<(start + originalCount)].elementsEqual(original.utf16) else {
            return .failure(.originalMismatch)
        }
        guard let unsafeDirection,
              unsafeDirection.firstMatch(in: snapshot.text,
                  range: NSRange(location: 0, length: wholeCount)) == nil,
              unsafeDirection.firstMatch(in: replacement,
                  range: NSRange(location: 0, length: replacementCount)) == nil else {
            return .failure(.unsupportedDirection)
        }
        let prefix = Array(whole[..<start])
        let suffix = Array(whole[(start + originalCount)...])
        guard isWellFormedUTF16(whole), isWellFormedUTF16(prefix), isWellFormedUTF16(suffix) else {
            return .failure(.invalidRange)
        }
        let resultUnits = prefix + Array(replacement.utf16) + suffix
        let result = NativeFieldObservation(text: String(decoding: resultUnits, as: UTF16.self),
            caretUTF16Location: start + replacementCount, selectionLength: 0)
        return .success(Self(originalSnapshot: snapshot, resultSnapshot: result,
            steps: [NativeFieldEditStep(operation: .insertReplacement,
                expectedBefore: snapshot, expectedAfter: result)]))
    }

    /// AX CFStrings can contain malformed UTF-16. Validate their raw units before
    /// constructing a Swift String, which would otherwise repair the evidence.
    static func isWellFormedUTF16(_ units: [UInt16]) -> Bool {
        var index = 0
        while index < units.count {
            let unit = units[index]
            if (0xD800...0xDBFF).contains(unit) {
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else { return false }
                index += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(unit) else { return false }
                index += 1
            }
        }
        return true
    }

    private static func isSimpleText(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf16.count <= maximumEditUnits,
              text.utf16.count == text.count else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            if (0x20...0x7E).contains(scalar.value) { return true }
            guard (0x0400...0x052F).contains(scalar.value) else { return false }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter: return true
            default: return false
            }
        }
    }
}
