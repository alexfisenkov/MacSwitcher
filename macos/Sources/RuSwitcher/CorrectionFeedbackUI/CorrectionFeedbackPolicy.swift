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
            ? "Текст не изменён. Кликните в нужное поле, выделите фрагмент и повторите двойной Shift."
            : "Text was not changed. Click the intended field, select the text, and press Shift twice again."
    }

    static func recoveryMessage(languageCode: String) -> String {
        languageCode == "ru"
            ? "Не удалось проверить результат. Исходный текст сохранён в MacSwitcher."
            : "Could not verify the result. The original text is preserved in MacSwitcher."
    }

    static func sourceMessage(languageCode: String) -> String {
        languageCode == "ru"
            ? "Текст исправлен. Выберите нужную раскладку в меню MacSwitcher."
            : "Text corrected. Choose the needed keyboard layout in the MacSwitcher menu."
    }
}
