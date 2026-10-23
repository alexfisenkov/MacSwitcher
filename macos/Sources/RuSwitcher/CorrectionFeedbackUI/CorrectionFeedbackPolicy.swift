/// Keep routine empty double-Shift attempts quiet. This policy uses only the
/// event-time target snapshot; it never reads text from the active application.
enum CorrectionFeedbackPolicy {
    static func hasManualTarget(selectionLength: Int, currentWordCount: Int,
                                previousWordCount: Int, boundaryCount: Int,
                                reconvert: Bool, hasReconversionState: Bool,
                                verifiedFallbackTarget: Bool = false) -> Bool {
        selectionLength > 0 || currentWordCount > 0
            || (previousWordCount > 0 && boundaryCount > 0)
            || (reconvert && hasReconversionState)
            || verifiedFallbackTarget
    }

    static func retryMessage(languageCode: String) -> String {
        languageCode == "ru"
            ? "Не получилось заменить. Выделите слово и нажмите Shift дважды."
            : "Could not replace the text. Select a word and press Shift twice."
    }

    static func recoveryMessage(languageCode: String) -> String {
        languageCode == "ru"
            ? "Не удалось проверить, заменился ли текст. Исходный текст сохранён в MacSwitcher. Откройте «Исходные тексты после сбоя» и скопируйте нужный текст."
            : "The text replacement could not be verified. The original text is retained in MacSwitcher. Open Recovery originals and copy it."
    }

    static func sourceMessage(languageCode: String) -> String {
        languageCode == "ru"
            ? "Текст исправлен, но раскладка не подтверждена. Выберите нужную раскладку в меню ввода macOS."
            : "The text was corrected, but the layout is unconfirmed. Select the needed layout in the macOS input menu."
    }
}
