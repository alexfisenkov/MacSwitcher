import XCTest
@testable import RuSwitcher

/// Every interface string speaks the interface language: no «Russian or English» choice in the code,
/// one name for automatic correction, the learning path built from the tab names.
final class LocalizationCoverageTests: XCTestCase {
    private let key = "com.ruswitcher.interfaceLanguage"

    private func withLanguage<T>(_ language: String, _ body: () throws -> T) rethrows -> T {
        let prior = UserDefaults.standard.object(forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            L10n.reloadLanguage()
        }
        UserDefaults.standard.set(language, forKey: key)
        L10n.reloadLanguage()
        return try body()
    }

    func testInterfaceSourcesNeverChooseBetweenRussianAndEnglishInline() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RuSwitcher", isDirectory: true)
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("languageCode == \"ru\"") || text.contains("languageCode == \"en\"") {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "inline ru/en choice must go through L10n tables")
    }

    func testAutomaticCorrectionHasOneNameInEveryLanguage() {
        let forbidden = ["Автокоррекц", "Автоматическая конверс", "Автоматична конверс", "Аўтаматычная канверс",
            "Automatic conversion", "Automatische Konvertierung", "Conversion automatique", "Conversión automática",
            "Conversão automática", "自动转换", "自動変換", "자동 변환", "Konwersja automatyczna", "Αυτόματη μετατροπή",
            "Автоматична конверсия", "Ինքնաշխատ փոխակերպում", "ავტომატური კონვერტაცია", "(beta)", "(бета)"]
        for language in L10n.supportedLanguages.sorted() {
            withLanguage(language) {
                let names = [L10n.nativeAutoTitle, L10n.menuAutoConvert, L10n.settingsAutoConvert, L10n.onboardAutoConvertTitle]
                XCTAssertEqual(Set(names).count, 1, "language=\(language): \(names)")
                for text in names + [L10n.nativeAutoHint, L10n.wordsNeverDetail, L10n.wordsAppsDetail,
                    L10n.settingsAutoConvertHint, L10n.onboardAutoConvertText] {
                    for old in forbidden {
                        XCTAssertFalse(text.contains(old), "language=\(language) still says \(old): \(text)")
                    }
                }
            }
        }
        withLanguage("ru") { XCTAssertEqual(L10n.menuAutoConvert, "Автоисправление") }
    }

    func testLearningPathIsBuiltFromTabNamesInEveryLanguage() {
        for language in L10n.supportedLanguages.sorted() {
            withLanguage(language) {
                XCTAssertTrue(L10n.adaptiveIntroBody.contains("\(L10n.nativeWordsTab) → \(L10n.nativeLearningEntry)"),
                    "language=\(language)")
                XCTAssertFalse(L10n.adaptiveIntroBody.contains("%"), "language=\(language)")
            }
        }
    }

    func testFeedbackMessagesFollowTheLanguageNotJustRussianOrEnglish() {
        let english = CorrectionFeedbackPolicy.retryMessage(languageCode: "en")
        for language in L10n.supportedLanguages where language != "en" {
            XCTAssertNotEqual(CorrectionFeedbackPolicy.retryMessage(languageCode: language), english, language)
            XCTAssertNotEqual(CorrectionFeedbackPolicy.sourceMessage(languageCode: language),
                CorrectionFeedbackPolicy.sourceMessage(languageCode: "en"), language)
            XCTAssertNotEqual(CorrectionFeedbackPolicy.recoveryMessage(languageCode: language),
                CorrectionFeedbackPolicy.recoveryMessage(languageCode: "en"), language)
        }
        XCTAssertTrue(CorrectionFeedbackPolicy.retryMessage(languageCode: "ru").hasPrefix("Текст не изменён"))
    }

    func testIntervalValueUsesTheLocalUnitInEveryLanguage() {
        let english = withLanguage("en") { L10n.settingsIntervalValue(150) }
        XCTAssertEqual(english, "150 ms")
        XCTAssertEqual(withLanguage("ru") { L10n.settingsIntervalValue(150) }, "150 мс")
        XCTAssertEqual(withLanguage("ja") { L10n.settingsIntervalValue(150) }, "150 ミリ秒")
        XCTAssertEqual(withLanguage("ka") { L10n.settingsIntervalValue(150) }, "150 მწმ")
    }
}
