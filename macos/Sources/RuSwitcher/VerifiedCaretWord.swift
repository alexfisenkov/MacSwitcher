import Foundation

/// Identifies only the complete word immediately left of a verified formatted caret.
/// The caller owns field identity, raw-to-formatted projection, and all edit revalidation.
enum VerifiedCaretWord {
    struct Match: Equatable {
        let word: String
        let convertedWord: String
        let spaces: String
        /// Exact range in the formatted field's UTF-16 coordinates.
        let range: NSRange
    }

    enum Outcome {
        case matched(Match)
        case refused(RuntimeDiagnosticFailureReason)
    }

    static func locate(in text: String, caretUTF16Location: Int,
                       context: CombinedShiftContext) -> Outcome {
        locate(in: text, caretUTF16Location: caretUTF16Location,
               convert: { DynamicKeyMapping.convert($0, context: context) })
    }

    /// The converter is supplied by the caller so the bounded locator itself
    /// depends only on its inputs and can be tested without system input sources.
    static func locate(in text: String, caretUTF16Location: Int,
                       convert: (String) -> String) -> Outcome {
        let length = text.utf16.count
        guard length <= NativeFieldEditPlan.maximumFieldUnits else {
            return .refused(.verifiedWordFieldMismatch)
        }
        guard caretUTF16Location >= 0, caretUTF16Location <= length else {
            return .refused(.verifiedWordCaretUnavailable)
        }
        // UTF-16 can point into a surrogate or an extended grapheme. Neither is
        // an unambiguous insertion boundary for the native editor.
        let caret = String.Index(utf16Offset: caretUTF16Location, in: text)
        guard caret.utf16Offset(in: text) == caretUTF16Location,
              text.indices.contains(caret) || caret == text.endIndex else {
            return .refused(.verifiedWordCaretUnavailable)
        }
        guard !TextConverter.containsRTL(text) else {
            return .refused(.verifiedWordFieldMismatch)
        }

        var prefix = Array(text[..<caret])
        var spaces = 0
        while prefix.last == " " {
            guard spaces < 16 else { return .refused(.verifiedWordTrailingSpaceLimit) }
            spaces += 1
            prefix.removeLast()
        }
        guard prefix.last?.isLetter == true else {
            return .refused(.verifiedWordNoFinalLetter)
        }

        var token: [Character] = []
        while let character = prefix.last {
            let internalKeyLetter = !token.isEmpty && !character.isLetter
                && ",.;'`[]\\".contains(character)
                && convert(String(character)).allSatisfy(\.isLetter)
            guard character.isLetter || internalKeyLetter else { break }
            guard token.count < 24 else { return .refused(.verifiedWordTokenLimit) }
            token.insert(character, at: 0)
            prefix.removeLast()
        }
        // A digit, URL/path punctuation, or an unrecognized mark immediately to
        // the left makes this a fragment of a larger technical/ambiguous token.
        guard prefix.last == nil || prefix.last?.isWhitespace == true else {
            return .refused(.verifiedWordBoundaryInvalid)
        }

        let word = String(token)
        guard !word.isEmpty, word.utf16.count <= 24,
              !word.unicodeScalars.contains(where: {
                  switch $0.properties.generalCategory {
                  case .nonspacingMark, .spacingMark, .enclosingMark: true
                  default: false
                  }
              }) else {
            return .refused(.verifiedWordTokenInvalid)
        }
        // Mapped punctuation is historically permitted at the genuine end of
        // the field. In an interior fragment it could also be a URL/path key.
        if caret != text.endIndex, token.contains(where: { !$0.isLetter }) {
            return .refused(.verifiedWordBoundaryInvalid)
        }
        // Interior caret is valid only at a real separator: either the safe
        // ASCII spaces are already behind it, or the next character is whitespace.
        if caret != text.endIndex, spaces == 0, !text[caret].isWhitespace {
            return .refused(.verifiedWordBoundaryInvalid)
        }
        let converted = convert(word)
        guard converted != word, !converted.isEmpty,
              converted.allSatisfy(\.isLetter) else {
            return .refused(.verifiedWordNoConversion)
        }
        let original = word + String(repeating: " ", count: spaces)
        let start = caretUTF16Location - original.utf16.count
        let range = NSRange(location: start, length: original.utf16.count)
        guard (text as NSString).substring(with: range).utf16.elementsEqual(original.utf16) else {
            return .refused(.verifiedWordFieldMismatch)
        }
        return .matched(Match(word: word, convertedWord: converted,
                              spaces: String(repeating: " ", count: spaces), range: range))
    }
}
