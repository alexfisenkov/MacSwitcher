import XCTest
@testable import RuSwitcher

final class NativeSelectedFieldEditTests: XCTestCase {
    private func selectedPlan(_ text: String = "ghbdtn", start: Int = 0, selectedStart: Int = 0,
                              selectedLength: Int = 6, original: String = "ghbdtn", replacement: String = "привет")
        -> Result<NativeFieldEditPlan, NativeFieldEditRefusal> {
        NativeFieldEditPlan.makeSelected(original: original, replacement: replacement, start: start,
            snapshot: NativeFieldObservation(text: text, caretUTF16Location: selectedStart,
                selectionLength: selectedLength))
    }

    func testSelectedPlanHasOnlyOneInsertionPreservingEmojiPrefixAndTail() throws {
        let prefix = "😀 e\u{301} "
        let tail = " tail 🧑🏽‍💻"
        let start = prefix.utf16.count
        let plan = try selectedPlan(prefix + "ghbdtn" + tail, start: start, selectedStart: start).get()
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.operation, .insertReplacement)
        XCTAssertEqual(plan.steps.first?.expectedBefore, plan.originalSnapshot)
        XCTAssertEqual(plan.steps.first?.expectedAfter, plan.resultSnapshot)
        XCTAssertEqual(Array(plan.resultSnapshot.text.utf16), Array((prefix + "привет" + tail).utf16))
        XCTAssertEqual(plan.resultSnapshot.caretUTF16Location, start + 6)
        XCTAssertEqual(plan.resultSnapshot.selectionLength, 0)
    }

    func testSelectedPlanAllowsLongUnicodeMultilineReplacementAndDifferentLengths() throws {
        let original = String(repeating: "a", count: 1000)
        let replacement = "строка\n😀 " + String(repeating: "б", count: 1000)
        let plan = try selectedPlan(original, selectedLength: 1000, original: original, replacement: replacement).get()
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(Array(plan.resultSnapshot.text.utf16), Array(replacement.utf16))
        XCTAssertEqual(plan.resultSnapshot.caretUTF16Location, replacement.utf16.count)
    }

    func testSelectedPlanRejectsMissingPartialWrongLocationAndMismatchedOriginal() {
        let results = [selectedPlan(selectedLength: 0), selectedPlan(selectedLength: 5),
            selectedPlan(selectedStart: 1), selectedPlan(start: -1), selectedPlan(start: Int.max),
            selectedPlan(original: "ghbdtN"), selectedPlan(original: "", replacement: "а"),
            selectedPlan(replacement: ""), selectedPlan(replacement: "ghbdtn")]
        for result in results { if case .success = result { XCTFail("Invalid selected edit accepted") } }
    }

    func testSelectedPlanBoundsOriginalAndResultAndRejectsRTL() {
        XCTAssertEqual(NativeFieldEditPlan.maximumSelectedReplacementUnits, 8192)
        let limit = String(repeating: "б", count: 8192)
        XCTAssertNoThrow(try selectedPlan(replacement: limit).get())
        if case .success = selectedPlan(replacement: limit + "б") { XCTFail("Oversized replacement") }
        let whole = "ghbdtn" + String(repeating: "a", count: NativeFieldEditPlan.maximumFieldUnits - 6)
        XCTAssertNoThrow(try selectedPlan(whole).get())
        if case .success = selectedPlan(whole, replacement: "привет!") { XCTFail("Oversized result") }
        for result in [selectedPlan("ghbdtn שלום"), selectedPlan(replacement: "שלום"),
                       selectedPlan(replacement: "\u{202E}привет")] {
            if case .success = result { XCTFail("Unsupported direction accepted") }
        }
    }

    @MainActor
    private final class Field {
        var text = "ghbdtn"
        var start = 0
        var selectedStart = 0
        var selectedLength = 6
        var original = "ghbdtn"
        var replacement = "привет"
        var clock: TimeInterval = 0
        var valid = true
        var barrier = true
        var editable = true
        var posted: [NativeFieldEditOperation] = []
        var prepared: [NativeFieldObservation] = []
        var deliver = true
        var truncatedToUnits: Int?
        var afterPost: (() -> Void)?
        var afterObservation: (() -> Void)?
        var observationOverride: ((Int) -> NativeFieldObservation?)?
        var observations = 0
        var pauses = 0

        var snapshot: NativeFieldObservation {
            NativeFieldObservation(text: text, caretUTF16Location: selectedStart, selectionLength: selectedLength)
        }
        func run() -> VerifiedNativeFieldEditResult {
            let access = NativeFieldAccess(validateOriginalIdentity: { _ in self.valid },
                cheapGate: { self.barrier }, isEditable: { _ in self.editable },
                observe: { _ in
                    self.observations += 1
                    self.afterObservation?()
                    return self.observationOverride?(self.observations) ?? self.snapshot
                }, postBatch: { operations in
                    guard operations == [.insertReplacement] else { return false }
                    self.posted.append(contentsOf: operations)
                    if self.deliver {
                        var units = Array(self.text.utf16)
                        let inserted = Array(self.replacement.utf16.prefix(self.truncatedToUnits ?? self.replacement.utf16.count))
                        units.replaceSubrange(self.selectedStart..<(self.selectedStart + self.selectedLength), with: inserted)
                        self.text = String(decoding: units, as: UTF16.self)
                        self.selectedStart += inserted.count
                        self.selectedLength = 0
                    }
                    self.afterPost?()
                    return true
                }, now: { self.clock }, pause: { interval in self.clock += interval; self.pauses += 1 })
            return VerifiedNativeFieldEditor.executeSelection(original: original, replacement: replacement,
                start: start, access: access, onPrepared: { self.prepared.append($0) })
        }
    }

    @MainActor
    func testSelectedExecutionConfirmsOnePairAndRetainsWholeOriginalBeforePosting() {
        let field = Field()
        let prefix = "😀 e\u{301} "
        let tail = " tail 🧑🏽‍💻"
        field.text = prefix + field.original + tail
        field.start = prefix.utf16.count
        field.selectedStart = field.start
        let initial = field.snapshot
        field.afterPost = { XCTAssertEqual(field.prepared, [initial]) }
        XCTAssertEqual(field.run(), .confirmed)
        XCTAssertEqual(field.posted, [.insertReplacement])
        XCTAssertEqual(field.text, prefix + "привет" + tail)
        XCTAssertEqual(field.selectedStart, field.start + 6)
        XCTAssertEqual(field.selectedLength, 0)
        XCTAssertEqual(field.prepared, [initial])
    }

    @MainActor
    func testLargeSelectedExecutionUsesOnePairWithoutNavigationOrDeletion() {
        let field = Field()
        field.original = String(repeating: "a", count: 1000)
        field.replacement = String(repeating: "б", count: 1000)
        field.text = "😀 " + field.original + " tail"
        field.start = "😀 ".utf16.count
        field.selectedStart = field.start
        field.selectedLength = 1000
        XCTAssertEqual(field.run(), .confirmed)
        XCTAssertEqual(field.posted, [.insertReplacement])
        XCTAssertEqual(field.text, "😀 " + field.replacement + " tail")
    }

    @MainActor
    func testSelectedTornOldTextWithNewCaretWaitsForExactFinalReadWithoutSecondInsertion() {
        let field = Field()
        field.observationOverride = { count in
            count == 3 ? NativeFieldObservation(text: "ghbdtn", caretUTF16Location: 6, selectionLength: 0) : nil
        }
        XCTAssertEqual(field.run(), .confirmed)
        XCTAssertEqual(field.posted, [.insertReplacement])
        XCTAssertEqual(field.text, "привет")
        XCTAssertEqual(field.observations, 4)
        XCTAssertEqual(field.pauses, 1)
    }

    @MainActor
    func testSelectedDeliveryTruncationIsUncertainActualStateWithNoRetry() {
        let field = Field()
        let initial = field.snapshot
        field.truncatedToUnits = 3
        let result = field.run()
        XCTAssertEqual(field.text, "при")
        XCTAssertEqual(result, .uncertain(observation: field.snapshot))
        XCTAssertEqual(field.posted, [.insertReplacement])
        XCTAssertEqual(field.prepared, [initial])
        XCTAssertGreaterThan(field.pauses, 0)
        XCTAssertLessThanOrEqual(field.clock, VerifiedNativeFieldEditor.maximumDuration)
    }

    @MainActor
    func testUndeliveredSelectedPairTimesOutWithoutSecondPostAndRetainsOriginal() {
        let field = Field()
        let initial = field.snapshot
        field.deliver = false
        XCTAssertEqual(field.run(), .uncertain(observation: initial))
        XCTAssertEqual(field.posted, [.insertReplacement])
        XCTAssertEqual(field.prepared, [initial])
        XCTAssertLessThanOrEqual(field.clock, 0.180)
    }

    @MainActor
    func testSelectedPreflightMismatchAndFieldChangeRefuseBeforePosting() {
        for failure in 0..<6 {
            let field = Field()
            switch failure {
            case 0: field.selectedLength = 5
            case 1: field.selectedStart = 1
            case 2: field.text = "ghbdtN"
            case 3: field.editable = false
            case 4: field.barrier = false
            default: field.afterObservation = { if field.observations == 2 { field.text = "different same-PID field" } }
            }
            XCTAssertEqual(field.run(), .refused)
            XCTAssertTrue(field.posted.isEmpty)
        }
    }

    @MainActor
    func testSelectedPostReadIdentityChangeNeverConfirmsOrPostsAgain() {
        let field = Field()
        let initial = field.snapshot
        field.afterPost = { field.valid = false }
        guard case .uncertain = field.run() else { return XCTFail("Lost original identity") }
        XCTAssertEqual(field.posted, [.insertReplacement])
        XCTAssertEqual(field.prepared, [initial])
    }
    @MainActor
    func testSelectedWholeFieldChangeAfterPostIsUncertainWithActualSnapshot() {
        let field = Field()
        let initial = field.snapshot
        field.afterPost = {
            field.text = "programmatically changed in same PID"
            field.selectedStart = 0
            field.selectedLength = 0
        }
        XCTAssertEqual(field.run(), .uncertain(observation: field.snapshot))
        XCTAssertEqual(field.posted, [.insertReplacement])
        XCTAssertEqual(field.prepared, [initial])
    }

    @MainActor
    func testUncollapsedSelectedResultNeverConfirmsAndNeverSendsAnotherPair() {
        let field = Field()
        field.afterPost = { field.selectedStart = 0; field.selectedLength = 6 }
        XCTAssertEqual(field.run(), .uncertain(observation: field.snapshot))
        XCTAssertEqual(field.posted, [.insertReplacement])
    }

}
