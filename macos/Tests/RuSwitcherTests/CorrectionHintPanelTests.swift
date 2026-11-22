import AppKit
import XCTest
@testable import RuSwitcher

/// The caret plate never takes focus or clicks and shows the offered word.
final class CorrectionHintPanelTests: XCTestCase {
    @MainActor
    func testPlateIsNonactivatingAndShowsTheOfferedWordNearTheCaret() {
        let hint = CorrectionHintPanel()
        XCTAssertTrue(hint.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(hint.panel.canBecomeKey)
        XCTAssertFalse(hint.panel.canBecomeMain)
        XCTAssertTrue(hint.panel.ignoresMouseEvents)
        let caret = NSRect(x: 300, y: 400, width: 0, height: 16)
        hint.update(word: "привет", near: caret)
        XCTAssertTrue(hint.label.stringValue.hasPrefix("привет"))
        XCTAssertTrue(hint.label.stringValue.contains("Shift ×2"))
        XCTAssertLessThanOrEqual(hint.panel.frame.maxY, caret.minY + 1)
        XCTAssertFalse(hint.isVisible)
    }

    func testHintTextIsLocalizedForRussianAndEnglish() {
        let saved = UserDefaults.standard.string(forKey: "com.ruswitcher.interfaceLanguage")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "com.ruswitcher.interfaceLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "com.ruswitcher.interfaceLanguage") }
            L10n.reloadLanguage()
        }
        UserDefaults.standard.set("ru", forKey: "com.ruswitcher.interfaceLanguage")
        L10n.reloadLanguage()
        XCTAssertEqual(L10n.correctionHint(word: "привет"), "привет  ·  Shift ×2 — исправить")
        UserDefaults.standard.set("en", forKey: "com.ruswitcher.interfaceLanguage")
        L10n.reloadLanguage()
        XCTAssertEqual(L10n.correctionHint(word: "hello"), "hello  ·  Shift ×2 to fix")
    }
}
