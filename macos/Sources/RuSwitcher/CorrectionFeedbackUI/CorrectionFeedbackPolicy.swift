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
        L10n.text("feedback.retry", language: languageCode)
    }

    static func recoveryMessage(languageCode: String, hasRecovery: Bool = true) -> String {
        L10n.text(hasRecovery ? "feedback.recovery.withArchive" : "feedback.recovery.noArchive", language: languageCode)
    }

    static func sourceMessage(languageCode: String) -> String {
        L10n.text("feedback.source", language: languageCode)
    }
}
