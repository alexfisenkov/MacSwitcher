import ApplicationServices
import XCTest
@testable import RuSwitcher

final class ConfirmedCorrectionReceiptsTests: XCTestCase {
    @MainActor
    func testExpiredToastCannotConsumeGestureUndoOfTheSameCurrentEdit() {
        var now: UInt64 = 100
        let store = ConfirmedCorrectionReceipts(now: { now })
        let notice = ConfirmedCorrectionNotice(id: UUID(), original: "f",
            replacement: "а", sourceLanguage: "en")
        let focus = CombinedShiftFocus(processID: 6071,
            element: AXUIElementCreateApplication(6071),
            initialSelection: CFRange(location: 1, length: 0), fieldBoundary: nil)
        let receipt = ConfirmedCorrectionReceipt(notice: notice, focus: focus,
            inputRevision: 7, sessionID: 3,
            sourceLayoutID: "en", resultLayoutID: "ru",
            editOriginal: "f", editReplacement: "а",
            before: NativeFieldObservation(text: "f", caretUTF16Location: 1, selectionLength: 0),
            after: NativeFieldObservation(text: "а", caretUTF16Location: 1, selectionLength: 0),
            issuedAt: now)
        XCTAssertTrue(store.retain(receipt))

        now += 16_000_000_000
        XCTAssertNil(store.claim(notice.id), "The toast action expires after 15 seconds")
        XCTAssertNotNil(store.claimForGesture(notice.id),
            "The unchanged current word must remain undoable after a pause")
        XCTAssertNil(store.claimForGesture(notice.id), "Gesture claim remains one-use")
    }
}
