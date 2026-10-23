import XCTest
@testable import RuSwitcher

final class CorrectionFeedbackPolicyTests: XCTestCase {
    func testEmptyManualTargetStaysQuietAndExplicitTargetGetsRetry() {
        func target(_ selection: Int = 0, _ word: Int = 0, _ previous: Int = 0,
                    _ boundaries: Int = 0, _ reconvert: Bool = false,
                    _ state: Bool = false) -> Bool {
            CorrectionFeedbackPolicy.hasManualTarget(selectionLength: selection,
                currentWordCount: word, previousWordCount: previous,
                boundaryCount: boundaries, reconvert: reconvert,
                hasReconversionState: state)
        }
        XCTAssertFalse(target())
        XCTAssertFalse(target(0, 0, 1, 0))
        XCTAssertFalse(target(0, 0, 0, 0, true, false))
        XCTAssertTrue(target(1))
        XCTAssertTrue(target(0, 1))
        XCTAssertTrue(target(0, 0, 1, 1))
        XCTAssertTrue(target(0, 0, 0, 0, true, true))
        XCTAssertTrue(CorrectionFeedbackPolicy.hasManualTarget(selectionLength: 0,
            currentWordCount: 0, previousWordCount: 0, boundaryCount: 0,
            reconvert: false, hasReconversionState: false, verifiedFallbackTarget: true))
        XCTAssertTrue(CorrectionFeedbackPolicy.retryMessage(languageCode: "ru").contains("Shift дважды"))
    }
}
