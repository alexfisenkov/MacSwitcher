import XCTest
@testable import RuSwitcher

final class NativeAutomaticTextEditorTests: XCTestCase {
    private enum Operation { case insertReplacement, moveLeft, deleteBackward, moveRight }
    @MainActor
    private final class Field {
        var text = "ghbd"
        var caret = 4
        var originalStart = 0
        var selectionLength = 0
        var valid = true
        var barrier = true
        var clock: TimeInterval = 0
        var operations: [Operation] = []
        var deliverInsertion = true
        var insertionResponse = true
        var afterOperation: ((Operation) -> Void)?
        var observation: ((Int) -> NativeAutomaticTextObservation?)?
        var pauseCount = 0
        var afterPause: (() -> Void)?
        var deletionResponse = true
        var leftResponse = true
        var rightResponse = true

        func access() -> NativeAutomaticTextAccess {
            NativeAutomaticTextAccess(
                isValid: { self.valid }, inputBarrierIsActive: { self.barrier },
                observe: { length in
                    if let observation = self.observation { return observation(length) }
                    let units = Array(self.text.utf16)
                    guard self.originalStart >= 0, self.originalStart <= units.count,
                          length <= units.count - self.originalStart else { return nil }
                    return NativeAutomaticTextObservation(
                        textFromOriginalStart: String(decoding: units[self.originalStart..<(self.originalStart + length)], as: UTF16.self),
                        caretUTF16Location: self.caret, selectionLength: self.selectionLength)
                },
                insertReplacement: { self.post(.insertReplacement) },
                deleteOriginal: {
                    for operation in Array(repeating: Operation.moveLeft, count: 4)
                        + Array(repeating: Operation.deleteBackward, count: 4)
                        + Array(repeating: Operation.moveRight, count: 4) {
                        guard self.valid, self.barrier, self.clock < 0.100, self.post(operation) else { return false }
                    }
                    return true
                }, pause: { interval in
                    self.clock += interval
                    self.pauseCount += 1
                    self.afterPause?()
                },
                now: { self.clock })
        }

        private func post(_ operation: Operation) -> Bool {
            operations.append(operation)
            var response = true
            switch operation {
            case .insertReplacement:
                if deliverInsertion {
                    let i = text.index(text.startIndex, offsetBy: caret)
                    text.insert(contentsOf: "прив", at: i)
                    caret += 4
                }
                response = insertionResponse
            case .moveLeft:
                caret -= 1
                response = leftResponse
            case .deleteBackward:
                text.remove(at: text.index(text.startIndex, offsetBy: caret - 1))
                caret -= 1
                response = deletionResponse
            case .moveRight:
                caret += 1
                response = rightResponse
            }
            afterOperation?(operation)
            return response
        }

        func run(original: String = "ghbd", replacement: String = "прив", start: Int = 0)
            -> NativeAutomaticTextEditResult {
            NativeAutomaticTextEditor.replace(original: original, replacement: replacement,
                originalStartUTF16: start, access: access())
        }
    }

    @MainActor
    func testConfirmedInsertFirstTransactionNeverDeletesBeforeDuplicateReadback() {
        let field = Field()
        var duplicateWasObserved = false
        field.observation = { length in
            if field.text == "ghbdприв", field.caret == 8, length == 8 { duplicateWasObserved = true }
            let units = Array(field.text.utf16)
            guard units.count >= length else { return nil }
            return NativeAutomaticTextObservation(textFromOriginalStart: String(decoding: units.prefix(length), as: UTF16.self),
                caretUTF16Location: field.caret, selectionLength: field.selectionLength)
        }
        field.afterOperation = { if $0 == .deleteBackward { XCTAssertTrue(duplicateWasObserved) } }
        XCTAssertEqual(field.run(), .confirmed)
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.caret, 4)
        XCTAssertEqual(field.operations, [.insertReplacement] + Array(repeating: .moveLeft, count: 4)
            + Array(repeating: .deleteBackward, count: 4) + Array(repeating: .moveRight, count: 4))
    }

    @MainActor
    func testInvalidOriginalSelectionOrBarrierRefusesBeforePosting() {
        for failure in 0..<5 {
            let field = Field()
            if failure == 0 { field.text = "gHbd" }
            if failure == 1 { field.caret = 3 }
            if failure == 2 { field.selectionLength = 1 }
            if failure == 3 { field.valid = false }
            if failure == 4 { field.barrier = false }
            XCTAssertEqual(field.run(), .refused)
            XCTAssertTrue(field.operations.isEmpty)
        }
    }

    @MainActor
    func testUndeliveredInsertionTimesOutWithoutAnyDeletion() {
        let field = Field()
        field.deliverInsertion = false
        XCTAssertEqual(field.run(), .uncertain(recoveryText: "ghbdприв"))
        XCTAssertEqual(field.text, "ghbd")
        XCTAssertEqual(field.operations, [.insertReplacement])
        XCTAssertLessThanOrEqual(field.clock, 0.101)
    }

    @MainActor
    func testDelayedInsertionWithinBudgetCanBeVerifiedBeforeDeletion() {
        let field = Field()
        field.deliverInsertion = false
        field.afterPause = {
            if field.pauseCount == 2 { field.text = "ghbdприв"; field.caret = 8 }
        }
        XCTAssertEqual(field.run(), .confirmed)
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.pauseCount, 2)
        XCTAssertEqual(field.operations.filter { $0 == .insertReplacement }.count, 1)
    }

    @MainActor
    func testNonzeroAbsoluteStartPreservesBothNeighbours() {
        let field = Field()
        field.text = "xx ghbd tail"
        field.caret = 7
        field.originalStart = 3
        XCTAssertEqual(field.run(start: 3), .confirmed)
        XCTAssertEqual(field.text, "xx прив tail")
        XCTAssertEqual(field.caret, 7)
    }

    @MainActor
    func testFailedInsertionResponseStopsEvenIfInsertionWasDelivered() {
        let field = Field()
        field.insertionResponse = false
        XCTAssertEqual(field.run(), .uncertain(recoveryText: "ghbdприв"))
        XCTAssertEqual(field.text, "ghbdприв")
        XCTAssertEqual(field.operations, [.insertReplacement])
    }

    @MainActor
    func testChangedValidityOrLostBarrierAfterInsertionNeverNavigatesOrDeletes() {
        for loseBarrier in [false, true] {
            let field = Field()
            field.afterOperation = { _ in
                if loseBarrier { field.barrier = false } else { field.valid = false }
            }
            XCTAssertEqual(field.run(), .uncertain(recoveryText: "ghbdприв"))
            XCTAssertEqual(field.operations, [.insertReplacement])
        }
    }

    @MainActor
    func testWrongCaretOrNonCollapsedInsertionReadbackNeverDeletes() {
        for nonCollapsed in [false, true] {
            let field = Field()
            field.afterOperation = { operation in
                guard operation == .insertReplacement else { return }
                if nonCollapsed { field.selectionLength = 1 } else { field.caret = 7 }
            }
            XCTAssertEqual(field.run(), .uncertain(recoveryText: "ghbdприв"))
            XCTAssertEqual(field.operations, [.insertReplacement])
        }
    }

    @MainActor
    func testStaleInsertionAXReadbackCannotAuthorizeDeletion() {
        let field = Field()
        var reads = 0
        field.observation = { length in
            reads += 1
            if reads == 1 {
                return NativeAutomaticTextObservation(textFromOriginalStart: "ghbd", caretUTF16Location: 4, selectionLength: 0)
            }
            return NativeAutomaticTextObservation(textFromOriginalStart: "ghbd", caretUTF16Location: 4, selectionLength: 0)
        }
        XCTAssertEqual(field.run(), .uncertain(recoveryText: "ghbdприв"))
        XCTAssertEqual(field.operations, [.insertReplacement])
    }

    @MainActor
    func testLateInsertionReadbackAtDeadlineNeverAuthorizesDeletion() {
        let field = Field()
        field.afterOperation = { if $0 == .insertReplacement { field.clock = 0.100 } }
        XCTAssertEqual(field.run(), .uncertain(recoveryText: "ghbdприв"))
        XCTAssertEqual(field.operations, [.insertReplacement])
    }

    @MainActor
    func testReadbackThatFinishesAfterDeadlineNeverAuthorizesDeletion() {
        let field = Field()
        field.observation = { length in
            let text = length == 4 ? "ghbd" : "ghbdприв"
            if length == 8 { field.clock = 0.101 }
            return NativeAutomaticTextObservation(textFromOriginalStart: text,
                caretUTF16Location: length, selectionLength: 0)
        }
        XCTAssertEqual(field.run(), .uncertain(recoveryText: "ghbdприв"))
        XCTAssertEqual(field.operations, [.insertReplacement])
    }

    @MainActor
    func testValidLookingReadbackAfterFocusChangeNeverAuthorizesDeletion() {
        let field = Field()
        field.observation = { length in
            if length == 8 { field.valid = false }
            return NativeAutomaticTextObservation(textFromOriginalStart: length == 4 ? "ghbd" : "ghbdприв",
                caretUTF16Location: length, selectionLength: 0)
        }
        XCTAssertEqual(field.run(), .uncertain(recoveryText: "ghbdприв"))
        XCTAssertEqual(field.operations, [.insertReplacement])
    }

    @MainActor
    func testPartialDeletionWithFalseResponseNeverContinuesOrRetries() {
        let field = Field()
        field.deletionResponse = false
        XCTAssertEqual(field.run(), .uncertain(recoveryText: "прив"))
        XCTAssertEqual(field.text, "ghbприв")
        XCTAssertEqual(field.operations.filter { $0 == .deleteBackward }.count, 1)
        XCTAssertFalse(field.operations.contains(.moveRight))
    }

    @MainActor
    func testBarrierOrDeadlineLossDuringDeletionStopsRemainingMutations() {
        for deadline in [false, true] {
            let field = Field()
            field.afterOperation = { operation in
                guard operation == .deleteBackward else { return }
                if deadline { field.clock = 0.101 } else { field.barrier = false }
            }
            XCTAssertEqual(field.run(), .uncertain(recoveryText: "прив"))
            XCTAssertEqual(field.operations.filter { $0 == .deleteBackward }.count, 1)
            XCTAssertFalse(field.operations.contains(.moveRight))
        }
    }

    @MainActor
    func testUnverifiedFinalReadbackIsUncertainAndNeverRunsAnotherMutation() {
        let field = Field()
        field.afterOperation = { operation in
            if operation == .moveRight, field.caret == 4 { field.selectionLength = 1 }
        }
        XCTAssertEqual(field.run(), .uncertain(recoveryText: "прив"))
        XCTAssertEqual(field.text, "прив")
        XCTAssertEqual(field.operations.count, 13)
    }

    @MainActor
    func testUnsafeOrUnequalTextRefusesWithoutMutation() {
        let cases = [("", ""), ("ghbd", "привет"), ("same", "same"), ("😀", "😃"),
                     ("a\u{0301}", "ab"), ("ab\n", "абв"), ("ab\u{202E}", "абв"),
                     (String(repeating: "a", count: 21), String(repeating: "б", count: 21))]
        for (original, replacement) in cases {
            let field = Field()
            XCTAssertEqual(field.run(original: original, replacement: replacement), .refused)
            XCTAssertTrue(field.operations.isEmpty)
        }
    }

    @MainActor
    func testInvalidOffsetsNonfiniteClockAndBackwardClockRefuse() {
        for start in [-1, Int.max] {
            let field = Field()
            XCTAssertEqual(field.run(start: start), .refused)
            XCTAssertTrue(field.operations.isEmpty)
        }
        for clock in [TimeInterval.nan, TimeInterval.infinity] {
            let field = Field()
            field.clock = clock
            XCTAssertEqual(field.run(), .refused)
            XCTAssertTrue(field.operations.isEmpty)
        }
        let field = Field()
        field.afterOperation = { _ in field.clock = -1 }
        XCTAssertEqual(field.run(), .uncertain(recoveryText: "ghbdприв"))
        XCTAssertEqual(field.operations, [.insertReplacement])
    }
}
