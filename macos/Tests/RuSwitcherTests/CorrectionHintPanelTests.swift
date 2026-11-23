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

    /// Under the raised flag the plate follows the auto-correction rule per
    /// field: an ordinary field outside the holder gets the plate at its caret;
    /// a password field, the holder's own field or an unsure AX answer gets
    /// neither a caret read nor a plate.
    @MainActor
    func testRaisedFlagShowsThePlateOnlyInAnOrdinaryFieldByTheSameRule() throws {
        let restore = raiseSyntheticSecureFlag(holder: 77)
        defer { restore() }
        let caret = NSRect(x: 300, y: 400, width: 0, height: 16)
        let ordinary: (AXError, AnyObject?) = (.attributeUnsupported, nil)
        let password: (AXError, AnyObject?) = (.success, kAXSecureTextFieldSubrole as NSString)
        let unsure: (AXError, AnyObject?) = (.cannotComplete, nil)
        for (name, pid, subrole, shown) in [("ordinary", Int32(501), ordinary, true),
                                            ("password", 501, password, false),
                                            ("holder", 77, ordinary, false),
                                            ("unsure", 501, unsure, false)] {
            var reads = 0
            let plate = CorrectionHintPanel(flagRaised: { true }, readCaret: { _ in reads += 1; return caret })
            defer { plate.hide() }
            let hint = try Self.hint(processID: pid, subrole: subrole)
            XCTAssertEqual(plate.show(hint), shown, name)
            XCTAssertEqual(plate.isVisible, shown, name)
            XCTAssertEqual(reads, shown ? 1 : 0, "\(name): caret read")
            if shown { XCTAssertLessThanOrEqual(plate.panel.frame.maxY, caret.minY + 1, "\(name): at the caret") }
        }
    }

    private static func hint(processID: Int32, subrole: (AXError, AnyObject?)) throws -> PendingCorrectionHint {
        let edit = try XCTUnwrap(PredictionSuffixEdit(original: "ghbdtn", replacement: "привет"))
        let focus = CombinedShiftFocus(processID: processID, element: AXUIElementCreateApplication(processID),
            initialSelection: CFRange(location: 6, length: 0), fieldBoundary: CombinedShiftFieldBoundary(
                validationFailure: { nil }, selectionRange: { CFRange(location: 6, length: 0) },
                text: { _ in nil }, secureSubrole: { subrole }))
        return PendingCorrectionHint(proposal: PredictionProposal(originalSuffix: "ghbdtn",
            replacementSuffix: "привет", targetLanguage: "ru", reason: .typo), edit: edit, focus: focus,
            caretUTF16Location: 6, inputRevision: 1, sessionID: 1, sourceLayoutID: "en",
            resultLayoutID: "ru", sourceLanguage: "en", issuedAt: 0)
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
