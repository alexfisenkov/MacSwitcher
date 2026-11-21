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

    static func recoveryMessage(languageCode: String, hasRecovery: Bool = true) -> String {
        if !hasRecovery {
            return languageCode == "ru"
                ? "Результат правки не подтверждён. Проверьте поле. Если повтор в нём ничего не меняет, начните ввод в другом поле или окне."
                : "The edit could not be confirmed. Check the field. If another attempt there changes nothing, start typing in a different field or window."
        }
        return languageCode == "ru"
            ? "Результат правки не подтверждён. Откройте исходный текст кнопкой или через меню MacSwitcher, затем скопируйте его. Если повтор в том же поле ничего не меняет, начните ввод в другом поле или окне."
            : "The edit could not be confirmed. Open the original text with the button or MacSwitcher menu, then copy it. If another attempt in the same field changes nothing, start typing in a different field or window."
    }

    static func sourceMessage(languageCode: String) -> String {
        languageCode == "ru"
            ? "Текст исправлен. Выберите нужную раскладку в меню MacSwitcher."
            : "Text corrected. Choose the needed keyboard layout in the MacSwitcher menu."
    }
}
