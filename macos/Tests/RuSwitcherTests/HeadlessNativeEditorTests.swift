import AppKit
import XCTest
@testable import RuSwitcher

/// Actual AppKit text storage/selection semantics without a window, AX, global
/// input, input-source changes, or activation. OS delivery is exercised by the
/// separate standalone HeadlessNativeFixture, not these deterministic tests.
final class HeadlessNativeEditorTests: XCTestCase {
    @MainActor
    private final class Field {
        let view: NSTextView
        let other = NSTextView(frame: .zero)
        var original = "ghbd"
        var replacement = "прив"
        var start = 0
        var clock: TimeInterval = 0
        var identityValid = true
        var fenceActive = true
        var batchCalls = 0
        var cancellationCalls = 0
        var textQueued = false
        var ignoreUnicode = false
        var queued: [NativeFieldEditOperation] = []
        var delivered: [NativeFieldEditOperation] = []
        var states: [NativeFieldObservation] = []
        var deliverOnPause = true
        var afterBatch: (() -> Void)?
        var afterObserve: (() -> Void)?

        init(text: String = "ghbd", caret: Int = 4, selected: Int = 0) {
            NSApplication.shared.setActivationPolicy(.prohibited)
            view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.string = text
            view.setSelectedRange(NSRange(location: caret, length: selected))
            other.string = "SECOND_FIELD_SENTINEL"
        }

        var snapshot: NativeFieldObservation {
            let range = view.selectedRange()
            return NativeFieldObservation(text: view.string, caretUTF16Location: range.location, selectionLength: range.length)
        }

        func deliverNext() {
            guard !queued.isEmpty else { return }
            let operation = queued.removeFirst()
            switch operation {
            case .selectPreviousCharacter: view.moveLeftAndModifySelection(nil)
            case .insertReplacement:
                if !ignoreUnicode { view.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            case .left: view.moveLeft(nil)
            case .backspace: view.deleteBackward(nil)
            case .right: view.moveRight(nil)
            }
            delivered.append(operation)
            states.append(snapshot)
        }
        func flush() { while !queued.isEmpty { deliverNext() } }

        func access() -> NativeFieldAccess {
            NativeFieldAccess(validateOriginalIdentity: { _ in self.identityValid }, cheapGate: { self.fenceActive },
                isEditable: { _ in self.view.isEditable }, observe: { _ in
                    let value = self.snapshot
                    self.afterObserve?()
                    return value
                }, postBatch: { operations in
                    guard self.identityValid, self.fenceActive else { return false }
                    self.batchCalls += 1
                    self.queued.append(contentsOf: operations)
                    self.afterBatch?()
                    return true
                }, cancelPreparedSelection: { _ in
                    guard self.fenceActive else { return false }
                    self.cancellationCalls += 1
                    self.queued += [.selectPreviousCharacter, .right]
                    return true
                }, now: { self.clock }, pause: { interval in
                    self.clock += interval
                    if self.deliverOnPause { self.deliverNext() }
                })
        }
        func run(selected: Bool = false) -> VerifiedNativeFieldEditResult {
            if selected {
                return VerifiedNativeFieldEditor.executeSelection(original: original, replacement: replacement,
                    start: start, access: access(), onTextQueued: { self.textQueued = true })
            }
            return VerifiedNativeFieldEditor.execute(original: original, replacement: replacement,
                start: start, access: access(), onTextQueued: { self.textQueued = true })
        }
    }

    @MainActor
    func testRealAppKitSelectionStatesMatchPlanAndPreserveUnicodeNeighbours() throws {
        let prefix = "😀 e\u{301} "
        let tail = " tail 🧑🏽‍💻"
        let field = Field(text: prefix + "ghbd" + tail, caret: prefix.utf16.count + 4)
        field.start = prefix.utf16.count
        let plan = try NativeFieldEditPlan.make(original: field.original, replacement: field.replacement,
            start: field.start, snapshot: field.snapshot).get()
        XCTAssertEqual(field.run(), .confirmed)
        XCTAssertEqual(field.batchCalls, 2)
        field.flush()
        XCTAssertEqual(Array(field.states.prefix(plan.steps.count)), plan.steps.map(\.expectedAfter))
        XCTAssertEqual(field.snapshot, plan.resultSnapshot)
        XCTAssertEqual(field.other.string, "SECOND_FIELD_SENTINEL")
        XCTAssertNil(field.view.window)
        XCTAssertFalse(NSApplication.shared.windows.contains(where: \.isVisible))
    }

    @MainActor
    func testSelectionNeverDeletesOrDuplicatesOriginalBeforeSingleReplacement() {
        let field = Field()
        XCTAssertEqual(field.run(), .confirmed)
        field.flush()
        XCTAssertEqual(field.delivered, Array(repeating: .selectPreviousCharacter, count: 4) + [.insertReplacement, .selectPreviousCharacter, .right])
        XCTAssertTrue(field.states.prefix(4).allSatisfy { $0.text == "ghbd" })
        XCTAssertEqual(field.view.string, "прив")
    }

    @MainActor
    func testExpiredPreparationCancelsSelectionBeforeOriginalSourceContinuation() {
        let field = Field()
        field.deliverOnPause = false
        XCTAssertEqual(field.run(), .refused)
        XCTAssertEqual(field.view.string, "ghbd")
        XCTAssertEqual(field.queued.count, 6)
        XCTAssertEqual(field.batchCalls, 1)
        XCTAssertEqual(field.cancellationCalls, 1)
        XCTAssertFalse(field.textQueued)
        // Refusal is before text; this drains queued FIFO cleanup only and does not prove delivery.
        field.flush()
        field.view.insertText("tn", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(field.view.string, "ghbdtn")
        XCTAssertEqual(field.view.selectedRange(), NSRange(location: 6, length: 0))
        XCTAssertEqual(field.batchCalls, 1)
    }

    @MainActor
    func testIdentityLossBeforeAdmissionKeepsBothRealTextViewsUntouched() {
        let field = Field()
        field.afterObserve = { field.identityValid = false }
        XCTAssertEqual(field.run(), .refused)
        XCTAssertEqual(field.batchCalls, 0)
        XCTAssertEqual(field.view.string, "ghbd")
        XCTAssertEqual(field.other.string, "SECOND_FIELD_SENTINEL")
    }

    @MainActor
    func testGateLossAfterPreparationNeverQueuesReplacement() {
        let field = Field()
        field.afterBatch = { field.fenceActive = false }
        guard case .uncertain = field.run() else { return XCTFail("Fence loss is not confirmation") }
        XCTAssertEqual(field.queued.count, 4)
        field.flush()
        XCTAssertEqual(field.view.string, "ghbd")
        XCTAssertEqual(field.batchCalls, 1)
        XCTAssertEqual(field.delivered.count, 4)
        XCTAssertFalse(field.textQueued)
    }

    @MainActor
    func testSelectedMultilineTextUsesOneNativeReplacementAndPreservesNeighbours() {
        let original = "ghbdtn\nghbdtn"
        let replacement = "привет\nпривет"
        let prefix = "😀 "
        let field = Field(text: prefix + original + " END", caret: prefix.utf16.count, selected: original.utf16.count)
        field.original = original
        field.replacement = replacement
        field.start = prefix.utf16.count
        XCTAssertEqual(field.run(selected: true), .confirmed)
        XCTAssertEqual(field.delivered, [.insertReplacement])
        XCTAssertEqual(field.view.string, prefix + replacement + " END")
        XCTAssertEqual(field.view.selectedRange(), NSRange(location: prefix.utf16.count + replacement.utf16.count, length: 0))
    }

    @MainActor
    func testReadOnlyRealTextViewRefusesBatch() {
        let field = Field()
        field.view.isEditable = false
        XCTAssertEqual(field.run(), .refused)
        XCTAssertEqual(field.batchCalls, 0)
        XCTAssertEqual(field.view.string, "ghbd")
    }

    @MainActor
    func testMaximumOrdinaryEditUsesTwentyFourSelectionsAndOneInsertion() {
        let original = String(repeating: "a", count: 24)
        let field = Field(text: original, caret: original.utf16.count)
        field.original = original
        field.replacement = String(repeating: "ф", count: 24)
        XCTAssertEqual(field.run(), .confirmed)
        field.flush()
        XCTAssertEqual(field.delivered.count, 27)
        XCTAssertEqual(field.view.string, field.replacement)
    }

    @MainActor
    func testIgnoredUnicodeStabilizationPreservesOriginalBeforeNextLetter() {
        let field = Field()
        field.ignoreUnicode = true
        guard case .uncertain = field.run() else { return XCTFail("Dropped Unicode cannot confirm") }
        field.flush()
        XCTAssertTrue(field.textQueued)
        XCTAssertEqual(field.view.string, "ghbd")
        XCTAssertEqual(field.view.selectedRange(), NSRange(location: 4, length: 0))
        field.view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(field.view.string, "ghbdx")
    }

    @MainActor
    func testStabilizationPreservesPositiveCollapsedCaretWithSuffix() {
        let field = Field(text: "ghbd END", caret: 4)
        field.queued = [.selectPreviousCharacter, .right]
        field.flush()
        XCTAssertEqual(field.view.string, "ghbd END")
        XCTAssertEqual(field.view.selectedRange(), NSRange(location: 4, length: 0))
    }

    @MainActor
    func testOversizedEditAndNonCollapsedOrdinarySelectionRefuseWithoutInput() {
        let original = String(repeating: "a", count: 25)
        let tooLong = Field(text: original, caret: original.utf16.count)
        tooLong.original = original
        tooLong.replacement = String(repeating: "ф", count: 25)
        let selected = Field(text: "ghbd", caret: 0, selected: 4)
        for field in [tooLong, selected] {
            XCTAssertEqual(field.run(), .refused)
            XCTAssertEqual(field.batchCalls, 0)
            XCTAssertEqual(field.view.string, field === tooLong ? original : "ghbd")
        }
    }
}
