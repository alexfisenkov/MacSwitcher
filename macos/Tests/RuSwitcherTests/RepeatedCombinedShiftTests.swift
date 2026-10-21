import ApplicationServices
import XCTest
@testable import RuSwitcher

final class RepeatedCombinedShiftTests: XCTestCase {
    private struct InstalledPair {
        let englishID: String
        let russianID: String
        let englishToRussian: CombinedShiftContext
        let russianToEnglish: CombinedShiftContext

        var contextBySource: [String: CombinedShiftContext] {
            [englishID: englishToRussian, russianID: russianToEnglish]
        }
    }

    private func fixturePair() -> InstalledPair {
        // These identifiers describe the synthetic input stream; no installed
        // source lookup or system layout change is part of this buffer test.
        let englishID = "test.layout.english"
        let russianID = "test.layout.russian"
        return InstalledPair(englishID: englishID, russianID: russianID,
            englishToRussian: CombinedShiftContext(sourceLayoutID: englishID, targetLayoutID: russianID),
            russianToEnglish: CombinedShiftContext(sourceLayoutID: russianID, targetLayoutID: englishID))
    }

    @MainActor
    private func type(_ text: String, sourceID: String, pair: InstalledPair, into monitor: KeyboardMonitor) throws {
        let keyMap = sourceID == pair.englishID ? KeyMapping.keycodeToEN : KeyMapping.keycodeToRU
        for character in text {
            let keyCode = try XCTUnwrap(keyMap.first { $0.value == character }?.key,
                "No physical key mapping for \(character) in \(sourceID)")
            monitor.handleKeyDown(keyCode: keyCode, flags: [], renderedSourceLayoutID: sourceID)
        }
    }

    private func focus(processID: Int32 = 42) -> CombinedShiftFocus {
        // A stable AX identity token for request snapshots only. No AX message is sent.
        CombinedShiftFocus(processID: processID, element: AXUIElementCreateApplication(processID),
            initialSelection: CFRange(location: 0, length: 0))
    }

    @MainActor
    private func snapshot(_ action: CombinedShiftGesture.Action, monitor: KeyboardMonitor,
                          focus: CombinedShiftFocus, contexts: [String: CombinedShiftContext]) -> CombinedShiftRequest? {
        let processID = focus.processID
        return monitor.snapshotCombinedShiftRequest(action: action, frontProcessID: processID, focus: focus,
            contextForSource: { contexts[$0] })
    }

    private func doubleActions(_ gesture: inout CombinedShiftGesture, firstContext: CombinedShiftContext,
                               secondContext: CombinedShiftContext, firstTapRelease: UInt64,
                               secondTapRelease: UInt64) -> (CombinedShiftGesture.Action?, CombinedShiftGesture.Action?) {
        gesture.press(.left, at: firstTapRelease - 20_000_000, context: firstContext)
        let first = gesture.release(.left, at: firstTapRelease)
        gesture.press(.right, at: secondTapRelease - 20_000_000, context: secondContext)
        let second = gesture.release(.right, at: secondTapRelease)
        return (first, second)
    }

    @MainActor
    func testManualShiftRequestSnapshotsRefreshAfterConversionAcknowledgementAndBoundary() throws {
        let pair = fixturePair()
        let monitor = KeyboardMonitor()
        let field = focus()
        let contexts = pair.contextBySource

        try type("ghbdtn", sourceID: pair.englishID, pair: pair, into: monitor)
        var gesture = CombinedShiftGesture()
        let firstActions = doubleActions(&gesture, firstContext: pair.englishToRussian,
            secondContext: pair.russianToEnglish, firstTapRelease: 50_000_000, secondTapRelease: 230_000_000)
        guard case .switchLayout(let firstDirection) = firstActions.0,
              case .convert(let firstConversionDirection) = firstActions.1 else {
            return XCTFail("Expected first single switch followed by a double-Shift conversion")
        }
        XCTAssertEqual(firstDirection, pair.englishToRussian)
        XCTAssertEqual(firstConversionDirection, pair.englishToRussian)

        let firstSwitch = try XCTUnwrap(snapshot(firstActions.0!, monitor: monitor, focus: field, contexts: contexts))
        let firstConversion = try XCTUnwrap(snapshot(firstActions.1!, monitor: monitor, focus: field, contexts: contexts))
        XCTAssertEqual(firstSwitch.wordKeys.count, 6)
        XCTAssertEqual(firstConversion.wordKeys.count, 6)
        XCTAssertEqual(firstConversion.wordContext, pair.englishToRussian)
        XCTAssertEqual(firstConversion.wordKeys.map(\.keyCode), [5, 4, 11, 2, 17, 45])
        XCTAssertEqual(firstConversion.action, .convert(pair.englishToRussian))
        XCTAssertTrue(CFEqual(firstSwitch.focus?.element, firstConversion.focus?.element))

        // This is the same state transition used after a confirmed production edit.
        monitor.markConverted()
        monitor.handleKeyDown(keyCode: KC.space, flags: [], renderedSourceLayoutID: pair.russianID)
        try type("руддщ", sourceID: pair.russianID, pair: pair, into: monitor)
        let nextActions = doubleActions(&gesture, firstContext: pair.russianToEnglish,
            secondContext: pair.englishToRussian, firstTapRelease: 500_000_000, secondTapRelease: 680_000_000)
        guard case .switchLayout(let nextDirection) = nextActions.0,
              case .convert(let nextConversionDirection) = nextActions.1 else {
            return XCTFail("Expected the next word to start a fresh double-Shift conversion")
        }
        XCTAssertEqual(nextDirection, pair.russianToEnglish)
        XCTAssertEqual(nextConversionDirection, pair.russianToEnglish)

        let nextSwitch = try XCTUnwrap(snapshot(nextActions.0!, monitor: monitor, focus: field, contexts: contexts))
        let nextConversion = try XCTUnwrap(snapshot(nextActions.1!, monitor: monitor, focus: field, contexts: contexts))
        XCTAssertEqual(nextSwitch.wordKeys.count, 5)
        XCTAssertEqual(nextConversion.wordKeys.count, 5)
        XCTAssertEqual(nextConversion.wordContext, pair.russianToEnglish)
        XCTAssertEqual(nextConversion.wordKeys.map(\.keyCode), [4, 14, 37, 37, 31])
        XCTAssertEqual(nextConversion.action, .convert(pair.russianToEnglish))
        XCTAssertFalse(nextConversion.reconvert, "Typing the next word must clear the prior conversion's undo flag")
        XCTAssertEqual(nextConversion.boundaryCount, 0)
        XCTAssertTrue(CFEqual(nextSwitch.focus?.element, nextConversion.focus?.element))
        XCTAssertEqual(firstConversion.frontProcessID, nextConversion.frontProcessID)
    }

    func testGestureBoundarySeparateSinglesAndTwoPairs() {
        let enToRu = CombinedShiftContext(sourceLayoutID: "en", targetLayoutID: "ru")
        let ruToEn = enToRu.reversed
        var gesture = CombinedShiftGesture()

        gesture.press(.left, at: 0, context: enToRu)
        XCTAssertEqual(gesture.release(.left, at: 20_000_000), .switchLayout(enToRu))
        gesture.press(.right, at: 160_000_000, context: ruToEn)
        XCTAssertEqual(gesture.release(.right, at: 200_000_000), .convert(enToRu),
            "A second release exactly 180 ms after the first remains a double")

        gesture.press(.left, at: 300_000_000, context: ruToEn)
        XCTAssertEqual(gesture.release(.left, at: 320_000_000), .switchLayout(ruToEn))
        gesture.press(.right, at: 481_000_000, context: enToRu)
        XCTAssertEqual(gesture.release(.right, at: 501_000_000), .switchLayout(enToRu),
            "A release beyond 180 ms starts a separate single switch")

        var secondPair = CombinedShiftGesture()
        secondPair.press(.left, at: 0, context: ruToEn)
        XCTAssertEqual(secondPair.release(.left, at: 20_000_000), .switchLayout(ruToEn))
        secondPair.press(.right, at: 160_000_000, context: enToRu)
        XCTAssertEqual(secondPair.release(.right, at: 200_000_000), .convert(ruToEn),
            "A second independent pair preserves its own original direction")
    }
}
