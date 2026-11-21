import Foundation
import XCTest
@testable import RuSwitcher

final class VerifiedCaretWordTests: XCTestCase {
    private func context() throws -> CombinedShiftContext {
        let layouts = LayoutSwitcher.installedLayouts()
        let english = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "en" })
        let russian = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0) == "ru" })
        return CombinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(english),
                                    targetLayoutID: LayoutSwitcher.sourceID(russian))
    }

    private func match(_ text: String, caret: Int, context: CombinedShiftContext,
                       file: StaticString = #filePath, line: UInt = #line) throws -> VerifiedCaretWord.Match {
        guard case let .matched(found) = VerifiedCaretWord.locate(in: text,
            caretUTF16Location: caret, context: context) else {
            XCTFail("Expected a bounded word at the verified caret", file: file, line: line)
            throw NSError(domain: "VerifiedCaretWordTests", code: 1)
        }
        return found
    }

    private func refusal(_ text: String, caret: Int, context: CombinedShiftContext,
                         file: StaticString = #filePath, line: UInt = #line) -> RuntimeDiagnosticFailureReason? {
        guard case let .refused(reason) = VerifiedCaretWord.locate(in: text,
            caretUTF16Location: caret, context: context) else {
            XCTFail("Expected a closed refusal", file: file, line: line)
            return nil
        }
        return reason
    }

    func testExactEndAndRepeatedLaterWordUseCaretLocation() throws {
        let pair = try context()
        let text = "ghbdtn ghbdtn"
        let later = try match(text, caret: text.utf16.count, context: pair)
        XCTAssertEqual(later.word, "ghbdtn")
        XCTAssertEqual(later.spaces, "")
        XCTAssertEqual(later.range, NSRange(location: 7, length: 6))
        XCTAssertEqual((text as NSString).substring(with: later.range), later.word + later.spaces)
        XCTAssertEqual(later.convertedWord, "привет")
    }

    func testHistoricalMappedInternalKeyboardPunctuationAtTrueEnd() throws {
        let pair = try context()
        let word = "j,sxyj"
        let found = try match(word, caret: word.utf16.count, context: pair)
        XCTAssertEqual(found.word, word)
        XCTAssertEqual(found.convertedWord, "обычно")
        XCTAssertEqual(found.range, NSRange(location: 0, length: 6))
        XCTAssertEqual(refusal(word + " next", caret: 6, context: pair), .verifiedWordBoundaryInvalid)
    }

    func testPureMappingClosureConvertsCompleteWordOnlyOnce() {
        var inputs: [String] = []
        let outcome = VerifiedCaretWord.locate(in: "ghbdtn suffix", caretUTF16Location: 6) {
            inputs.append($0)
            return $0 == "ghbdtn" ? "привет" : $0
        }
        guard case let .matched(found) = outcome else {
            return XCTFail("Expected the immediate complete word")
        }
        XCTAssertEqual(found.convertedWord, "привет")
        XCTAssertEqual(inputs, ["ghbdtn"])
    }

    func testInteriorWordLeavesExactSuffixAndPreservesSpaces() throws {
        let pair = try context()
        let text = "ghbdtn ghbdtn  Z🙂"
        let caret = "ghbdtn ghbdtn  ".utf16.count
        let found = try match(text, caret: caret, context: pair)
        XCTAssertEqual(found.range, NSRange(location: 7, length: 8))
        XCTAssertEqual(found.word, "ghbdtn")
        XCTAssertEqual(found.spaces, "  ")
        let edited = (text as NSString).replacingCharacters(in: found.range, with: "привет" + found.spaces)
        XCTAssertEqual(edited, "ghbdtn привет  Z🙂")
    }

    func testInteriorWithoutLeftSpacesRequiresWhitespaceAfterCaret() throws {
        let pair = try context()
        let text = "ghbdtn next"
        let found = try match(text, caret: 6, context: pair)
        XCTAssertEqual(found.range, NSRange(location: 0, length: 6))
        XCTAssertEqual(refusal("ghbdtnnext", caret: 6, context: pair), .verifiedWordBoundaryInvalid)
    }

    func testInvalidEmptyStaleAndInteriorCaretFailClosed() throws {
        let pair = try context()
        XCTAssertEqual(refusal("", caret: 0, context: pair), .verifiedWordNoFinalLetter)
        XCTAssertEqual(refusal("ghbdtn", caret: -1, context: pair), .verifiedWordCaretUnavailable)
        XCTAssertEqual(refusal("ghbdtn", caret: 7, context: pair), .verifiedWordCaretUnavailable)
        XCTAssertEqual(refusal("ghbdtn", caret: 3, context: pair), .verifiedWordBoundaryInvalid)
    }

    func testSurrogateAndCombiningBoundariesFailClosed() throws {
        let pair = try context()
        XCTAssertEqual(refusal("🙂ghbdtn", caret: 1, context: pair), .verifiedWordCaretUnavailable)
        XCTAssertEqual(refusal("e\u{301} next", caret: 1, context: pair), .verifiedWordCaretUnavailable)
        XCTAssertEqual(refusal("e\u{301} next", caret: 2, context: pair), .verifiedWordTokenInvalid)
    }

    func testTechnicalPrefixesAndLogicalLineBoundary() throws {
        let pair = try context()
        XCTAssertEqual(refusal("abc/ghbdtn ", caret: 11, context: pair), .verifiedWordBoundaryInvalid)
        XCTAssertEqual(refusal("abc123ghbdtn", caret: 12, context: pair), .verifiedWordBoundaryInvalid)
        XCTAssertEqual(refusal("ghbdtn\nghbdtn", caret: 7, context: pair), .verifiedWordNoFinalLetter)
        let firstLine = try match("ghbdtn\nghbdtn", caret: 6, context: pair)
        XCTAssertEqual(firstLine.range, NSRange(location: 0, length: 6))
        let secondLine = try match("ghbdtn\nghbdtn", caret: 13, context: pair)
        XCTAssertEqual(secondLine.range.location, 7)
    }

    func testTrailingSpaceAndTokenBudgets() throws {
        let pair = try context()
        let maxSpaces = "ghbdtn" + String(repeating: " ", count: 16)
        XCTAssertEqual(try match(maxSpaces, caret: maxSpaces.utf16.count, context: pair).spaces.count, 16)
        XCTAssertEqual(refusal(maxSpaces + " ", caret: 23, context: pair), .verifiedWordTrailingSpaceLimit)
        XCTAssertEqual(refusal("ghbdtn\t ", caret: 8, context: pair), .verifiedWordNoFinalLetter)
        XCTAssertEqual(try match(String(repeating: "g", count: 24), caret: 24,
            context: pair).range.length, 24)
        XCTAssertEqual(refusal(String(repeating: "g", count: 25), caret: 25, context: pair), .verifiedWordTokenLimit)
    }

    func testRTLAndNoConversionFailClosed() throws {
        let pair = try context()
        XCTAssertEqual(refusal("ש ghbdtn", caret: 8, context: pair), .verifiedWordFieldMismatch)
        XCTAssertEqual(refusal("привет", caret: 6, context: pair), .verifiedWordNoConversion)
    }
}
