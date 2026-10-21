import AppKit
import XCTest
@testable import RuSwitcher

final class SelectionReplacementTests: XCTestCase {
    @MainActor
    private final class Field {
        var text = "ghbdtn"
        var range = CFRange(location: 0, length: 6)
        var valid = true
        var writable = true
        var writeSucceeds = true
        var deliversAXWrite = true
        var readbackMatches = true
        var writes = 0
        var selects = 0
        var selectSucceeds = true
        var deliversSelection = true
        var afterSelect: (() -> Void)?
        var afterWrite: (() -> Void)?

        func text(in range: CFRange) -> String? {
            let units = Array(text.utf16)
            guard range.location >= 0, range.length >= 0, range.location <= units.count,
                  range.length <= units.count - range.location else { return nil }
            return String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
        }

        func access() -> CombinedShiftSelectionAccess {
            CombinedShiftSelectionAccess(
                isValid: { self.valid },
                selection: {
                    guard let text = self.text(in: self.range) else { return nil }
                    return CombinedShiftSelectionSnapshot(range: self.range, text: text)
                },
                writeSelection: { replacement in
                    guard self.writable else { return nil }
                    self.writes += 1
                    if self.deliversAXWrite {
                        let units = Array(self.text.utf16)
                        let before = String(decoding: units[..<self.range.location], as: UTF16.self)
                        let after = String(decoding: units[(self.range.location + self.range.length)...], as: UTF16.self)
                        self.text = before + replacement + after
                        self.range = CFRange(location: self.range.location + replacement.utf16.count, length: 0)
                    }
                    self.afterWrite?()
                    return self.writeSucceeds
                },
                replacementIsCurrent: { original, replacement in
                    self.valid && self.readbackMatches && original.resultSnapshot(replacement: replacement,
                        selection: self.range, observedText: self.text(in: CFRange(
                            location: original.range.location, length: replacement.utf16.count))) != nil
                })
        }

        func suffixAccess() -> CombinedShiftSuffixAccess {
            CombinedShiftSuffixAccess(isValid: { self.valid }, selectionRange: { self.range },
                text: { self.text(in: $0) }, canWriteSelection: { self.writable },
                select: {
                    self.selects += 1
                    if self.deliversSelection { self.range = $0 }
                    self.afterSelect?()
                    return self.selectSucceeds
                }, selected: access())
        }
    }

    func testSelectionIdentityRequiresExactRangeAndUTF16Length() {
        let original = CombinedShiftSelectionSnapshot(range: CFRange(location: 2, length: 3), text: "😀a")
        XCTAssertNotNil(original)
        XCTAssertNil(CombinedShiftSelectionSnapshot(range: CFRange(location: 2, length: 2), text: "😀a"))
        XCTAssertNil(CombinedShiftSelectionSnapshot(range: CFRange(location: 2, length: 0), text: ""))
        XCTAssertFalse(original!.matches(range: CFRange(location: 3, length: 3), text: "😀a"))
        XCTAssertFalse(original!.matches(range: CFRange(location: 2, length: 3), text: "😀b"))
    }

    @MainActor
    func testWritableAXSelectionDoesNotTouchUserClipboard() {
        let field = Field()
        let board = NSPasteboard(name: NSPasteboard.Name("MacSwitcher.SelectionTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("user clipboard", forType: .string)
        let count = board.changeCount
        XCTAssertEqual(CombinedShiftSelectionEditor.replace(original: field.access().selection()!, replacement: "привет",
            access: field.access()), .confirmed)
        XCTAssertEqual(field.text, "привет")
        XCTAssertEqual(field.writes, 1)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), "user clipboard")
    }

    @MainActor
    func testUnsupportedSetterRefusesWithoutAnyWriteOrDelayedPaste() {
        let field = Field()
        field.writable = false
        XCTAssertEqual(CombinedShiftSelectionEditor.replace(original: field.access().selection()!, replacement: "привет",
            access: field.access()), .refused)
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.writes, 0)
        // The editor has no paste/wait callback: no delayed Cmd+V can consume a
        // restored or subsequently copied private clipboard after this refusal.
    }

    @MainActor
    func testChangedSelectionAndInvalidExecutionNeverWrite() {
        for invalidExecution in [false, true] {
            let field = Field()
            let original = field.access().selection()!
            if invalidExecution { field.valid = false } else { field.range = CFRange(location: 1, length: 5) }
            XCTAssertEqual(CombinedShiftSelectionEditor.replace(original: original, replacement: "привет",
                access: field.access()), .refused)
            XCTAssertEqual(field.writes, 0)
        }
    }

    @MainActor
    func testAXErrorWithUnverifiedMutationReturnsUnknownAndNeverWritesTwice() {
        let field = Field()
        let original = field.access().selection()!
        field.writeSucceeds = false
        field.readbackMatches = false
        XCTAssertEqual(CombinedShiftSelectionEditor.replace(original: original, replacement: "привет",
            access: field.access()), .unknown)
        XCTAssertEqual(field.text, "привет") // receiving editor mutated despite error
        XCTAssertEqual(original.text, "ghbdtn") // retained source remains available for explicit recovery
        XCTAssertEqual(field.writes, 1)
    }

    @MainActor
    func testAXSuccessWithoutVerifiedDeliveryReturnsUnknown() {
        let field = Field()
        field.deliversAXWrite = false
        XCTAssertEqual(CombinedShiftSelectionEditor.replace(original: field.access().selection()!, replacement: "привет",
            access: field.access()), .unknown)
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.writes, 1)
    }

    @MainActor
    func testReadbackCanConfirmDeliveryEvenWhenAXReturnsError() {
        let field = Field()
        field.writeSucceeds = false
        XCTAssertEqual(CombinedShiftSelectionEditor.replace(original: field.access().selection()!, replacement: "привет",
            access: field.access()), .confirmed)
        XCTAssertEqual(field.writes, 1)
    }

    @MainActor
    func testInputOrFocusChangeAfterWriteLeavesOutcomeUnknown() {
        let field = Field()
        field.afterWrite = { field.valid = false }
        XCTAssertEqual(CombinedShiftSelectionEditor.replace(original: field.access().selection()!, replacement: "привет",
            access: field.access()), .unknown)
        XCTAssertEqual(field.writes, 1)
    }

    @MainActor
    func testUnknownTextWriteRestoresVerifiedUnchangedCaretButRemainsUnknown() throws {
        let field = Field()
        field.range = CFRange(location: 6, length: 0)
        field.deliversAXWrite = false
        let source = try XCTUnwrap(CombinedShiftSelectionSnapshot(range: CFRange(location: 0, length: 6), text: "ghbdtn"))
        XCTAssertEqual(CombinedShiftSuffixEditor.replace(original: source, replacement: "привет",
            expectedSelection: field.range, access: field.suffixAccess()), .unknown)
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.range.location, 6)
        XCTAssertEqual(field.range.length, 0)
        XCTAssertEqual(field.writes, 1)
        XCTAssertEqual(field.selects, 2)
    }

    @MainActor
    func testLargeSelectionUndoUsesExactResultRangeWithoutNativeDeletionLimit() throws {
        let field = Field()
        field.text = String(repeating: "ghbdtn ", count: 100)
        field.range.length = field.text.utf16.count
        let original = try XCTUnwrap(field.access().selection())
        let replacement = String(repeating: "привет ", count: 100)
        XCTAssertGreaterThan(original.text.count, 512)
        XCTAssertEqual(CombinedShiftSelectionEditor.replace(original: original, replacement: replacement,
            access: field.access()), .confirmed)
        let undo = try XCTUnwrap(original.resultSnapshot(replacement: replacement,
            selection: field.range, observedText: field.text))
        XCTAssertEqual(CombinedShiftSuffixEditor.replace(original: undo, replacement: original.text,
            expectedSelection: field.range, access: field.suffixAccess()), .confirmed)
        XCTAssertEqual(field.text, original.text)
        XCTAssertEqual(field.writes, 2)
        XCTAssertEqual(field.selects, 1)
    }

    func testUndoRefusesDifferentRangeOrChangedResultEvenWithIdenticalText() {
        let source = CombinedShiftSelectionSnapshot(range: CFRange(location: 2, length: 6), text: "ghbdtn")!
        XCTAssertNotNil(source.resultSnapshot(replacement: "привет", selection: CFRange(location: 8, length: 0), observedText: "привет"))
        XCTAssertNotNil(source.resultSnapshot(replacement: "привет", selection: CFRange(location: 2, length: 6), observedText: "привет"))
        XCTAssertNil(source.resultSnapshot(replacement: "привет", selection: CFRange(location: 15, length: 0), observedText: "привет"))
        XCTAssertNil(source.resultSnapshot(replacement: "привет", selection: CFRange(location: 8, length: 0), observedText: "Привет"))
    }

    @MainActor
    func testAutomaticSuffixUsesExactUTF16RangeAndPreservesBothNeighbours() {
        let field = Field()
        field.text = "😀 ghbdtn tail"
        field.range = CFRange(location: 9, length: 0)
        let source = CombinedShiftSelectionSnapshot(range: CFRange(location: 3, length: 6), text: "ghbdtn")!
        XCTAssertEqual(CombinedShiftSuffixEditor.replace(original: source, replacement: "привет",
            expectedSelection: field.range, access: field.suffixAccess()), .confirmed)
        XCTAssertEqual(field.text, "😀 привет tail")
        XCTAssertEqual(field.range.location, 9)
        XCTAssertEqual(field.selects, 1)
        XCTAssertEqual(field.writes, 1)
    }

    @MainActor
    func testAutomaticSuffixRejectsWrongCaretChangedSourceAndUnsupportedSetterBeforeSelection() {
        for failure in 0..<3 {
            let field = Field()
            field.range = CFRange(location: 6, length: 0)
            let expected = field.range
            if failure == 0 { field.range.location = 5 }
            if failure == 1 { field.text = "Ghbdtn" }
            if failure == 2 { field.writable = false }
            let source = CombinedShiftSelectionSnapshot(range: CFRange(location: 0, length: 6), text: "ghbdtn")!
            XCTAssertEqual(CombinedShiftSuffixEditor.replace(original: source, replacement: "привет",
                expectedSelection: expected, access: field.suffixAccess()), .refused)
            XCTAssertEqual(field.selects, 0)
            XCTAssertEqual(field.writes, 0)
        }
    }

    @MainActor
    func testAutomaticSuffixRechecksRevisionAndSourceAfterSelecting() {
        for changeText in [false, true] {
            let field = Field()
            field.range = CFRange(location: 6, length: 0)
            field.afterSelect = {
                if changeText { field.text = "Ghbdtn" } else { field.valid = false }
            }
            let source = CombinedShiftSelectionSnapshot(range: CFRange(location: 0, length: 6), text: "ghbdtn")!
            XCTAssertEqual(CombinedShiftSuffixEditor.replace(original: source, replacement: "привет",
                expectedSelection: field.range, access: field.suffixAccess()), .unknown)
            XCTAssertEqual(field.selects, 1)
            XCTAssertEqual(field.writes, 0)
        }
    }

    @MainActor
    func testUnsupportedSetterAfterSelectingRestoresOriginalCaretWithoutTextWrite() {
        let field = Field()
        field.range = CFRange(location: 6, length: 0)
        field.afterSelect = { field.writable = false }
        let source = CombinedShiftSelectionSnapshot(range: CFRange(location: 0, length: 6), text: "ghbdtn")!
        XCTAssertEqual(CombinedShiftSuffixEditor.replace(original: source, replacement: "привет",
            expectedSelection: field.range, access: field.suffixAccess()), .refused)
        XCTAssertEqual(field.text, "ghbdtn")
        XCTAssertEqual(field.range.location, 6)
        XCTAssertEqual(field.range.length, 0)
        XCTAssertEqual(field.selects, 2)
        XCTAssertEqual(field.writes, 0)
    }

    @MainActor
    func testSelectionSetterMutationDespiteFailureIsReconciledAndCaretRestored() {
        let field = Field()
        field.range = CFRange(location: 6, length: 0)
        field.selectSucceeds = false // AX error after the receiver changed selection
        let source = CombinedShiftSelectionSnapshot(range: CFRange(location: 0, length: 6), text: "ghbdtn")!
        XCTAssertEqual(CombinedShiftSuffixEditor.replace(original: source, replacement: "привет",
            expectedSelection: field.range, access: field.suffixAccess()), .refused)
        XCTAssertEqual(field.range.location, 6)
        XCTAssertEqual(field.range.length, 0)
        XCTAssertEqual(field.selects, 2)
        XCTAssertEqual(field.writes, 0)
    }

    @MainActor
    func testUndeliveredSelectionRefusalPreservesAlreadyOriginalCaret() {
        let field = Field()
        field.range = CFRange(location: 6, length: 0)
        field.selectSucceeds = false
        field.deliversSelection = false
        let source = CombinedShiftSelectionSnapshot(range: CFRange(location: 0, length: 6), text: "ghbdtn")!
        XCTAssertEqual(CombinedShiftSuffixEditor.replace(original: source, replacement: "привет",
            expectedSelection: field.range, access: field.suffixAccess()), .refused)
        XCTAssertEqual(field.range.location, 6)
        XCTAssertEqual(field.range.length, 0)
        XCTAssertEqual(field.selects, 1)
        XCTAssertEqual(field.writes, 0)
    }

    @MainActor
    func testPastedSelectionConvertsWithEitherActiveLayoutDirection() throws {
        let layouts = LayoutSwitcher.installedLayouts()
        let english = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0)?.hasPrefix("en") == true })
        let russian = try XCTUnwrap(layouts.first { LayoutSwitcher.languageCode($0)?.hasPrefix("ru") == true })
        let context = CombinedShiftContext(sourceLayoutID: LayoutSwitcher.sourceID(english),
            targetLayoutID: LayoutSwitcher.sourceID(russian))
        let converter = TextConverter()
        XCTAssertEqual(converter.selectionConversion("ghbdtn", context: context), "привет")
        XCTAssertEqual(converter.selectionConversion("ghbdtn", context: context.reversed), "привет")
        XCTAssertEqual(DynamicKeyMapping.resultContext(for: "привет", requested: context.reversed).targetLayoutID,
            context.targetLayoutID)
    }
}
