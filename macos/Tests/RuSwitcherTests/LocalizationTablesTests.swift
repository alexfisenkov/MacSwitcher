import XCTest
@testable import RuSwitcher

/// The translation tables are complete: 16 values per key, same format placeholders as English,
/// and no English left in the other languages.
final class LocalizationTablesTests: XCTestCase {
    private func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?[@d]")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .map { $0.replacingOccurrences(of: "%1$", with: "%").replacingOccurrences(of: "%2$", with: "%")
                .replacingOccurrences(of: "%3$", with: "%") }.sorted()
    }

    func testEveryKeyHasSixteenNonEmptyTranslationsWithTheSamePlaceholders() {
        XCTAssertGreaterThan(L10n.translations.count, 150)
        for (key, row) in L10n.translations.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(row.count, L10n.languageOrder.count, key)
            guard row.count == L10n.languageOrder.count else { continue }
            for (language, value) in zip(L10n.languageOrder, row) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) \(language)")
                XCTAssertEqual(placeholders(value), placeholders(row[0]), "\(key) \(language)")
                XCTAssertFalse(value.contains("\u{00AD}") || value.contains("{") || value.contains("}"), "\(key) \(language)")
            }
        }
    }

    func testLanguageOrderMatchesSupportedLanguages() {
        XCTAssertEqual(Set(L10n.languageOrder), L10n.supportedLanguages)
        XCTAssertEqual(L10n.languageOrder.count, 16)
    }

    func testOtherLanguagesAreTranslatedNotCopiedFromEnglish() {
        let intentionallyShared: Set<String> = ["settings.icon.badge", "settings.interval.value", "correction.hint"]
        var copied: [String] = []
        for (key, row) in L10n.translations where !intentionallyShared.contains(key) {
            for (index, language) in L10n.languageOrder.enumerated() where language != "en" {
                let value = row[index]
                let letters = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                guard letters > 3 else { continue }
                let english = row[0]
                if value == english && !["de", "fr", "es", "pt", "pl"].contains(language) { copied.append("\(key)/\(language)") }
                if value == english && ["de", "fr", "es", "pt", "pl"].contains(language) && english.count > 14 {
                    copied.append("\(key)/\(language)")
                }
            }
        }
        XCTAssertEqual(copied.sorted(), [])
    }

    func testTextLookupFallsBackToEnglishForUnknownLanguage() {
        XCTAssertEqual(L10n.text("welcome.done", language: "xx"), "Done")
        XCTAssertEqual(L10n.text("welcome.done", language: "de"), "Fertig")
        XCTAssertEqual(L10n.text("menu.copyOriginal", language: "ru", 3), "Скопировать исходный текст 3")
    }
}
