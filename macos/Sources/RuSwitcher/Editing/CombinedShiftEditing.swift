import Foundation

enum CombinedShiftFailure: Equatable {
    case unconfirmedEdit
    case noSafeEdit
    case sourceNotConfirmed

    var userMessage: String? {
        switch self {
        case .unconfirmedEdit:
            return "Результат записи не подтверждён. Исходный текст сохранён: откройте меню MacSwitcher → «Исходные тексты после сбоя», чтобы скопировать его. Не повторяйте замену вслепую."
        case .noSafeEdit:
            return "Исправление не выполнено: нет уверенной замены либо безопасную запись в это поле нельзя подтвердить. Проверьте выделение и фокус, затем при необходимости повторите жест."
        case .sourceNotConfirmed:
            return "Текст уже исправлен, но смена раскладки не подтверждена. Выберите раскладку для исправленного слова в меню ввода macOS или MacSwitcher и дождитесь её подтверждения. После этого можно продолжать ввод; повторный двойной Shift вернёт исходное написание."
        }
    }
}

enum CombinedShiftApplicationFamily: String, Equatable {
    case textEdit, codex, browser, other

    static func classify(bundleID: String?) -> Self {
        switch bundleID {
        case "com.apple.TextEdit": return .textEdit
        case "com.openai.codex": return .codex
        case "com.google.Chrome", "com.apple.Safari": return .browser
        default: return .other
        }
    }
}

struct CombinedShiftDiagnostic: Equatable {
    enum Operation: String, Equatable { case word, selection, undo }
    enum Result: String, Equatable { case confirmed, refused, uncertain }
    let application: CombinedShiftApplicationFamily
    let operation: Operation
    let result: Result
}

/// The edit decision shared by the live combined-Shift handler and its
/// headless field-transport regression. The caller owns the input lease and
/// confirms source selection after this operation returns.
@MainActor
enum CombinedShiftEditing {
    static func perform(request: CombinedShiftRequest, context: CombinedShiftContext,
                        execution: CombinedShiftExecutionContext, converter: TextConverter,
                        inputBarrierIsActive: @escaping () -> Bool,
                        convertWholeLine: Bool,
                        contextForSource: (String) -> CombinedShiftContext?,
                        onFailure: ((CombinedShiftFailure) -> Void)? = nil,
                        onDiagnostic: ((CombinedShiftDiagnostic) -> Void)? = nil,
                        application: CombinedShiftApplicationFamily = .other,
                        preparedSelection: TextConverter.PreparedNativeSelection? = nil,
                        fallbackSourceIsCurrent: (() -> Bool)? = nil,
                        automaticUndo: DoubleShiftAutomaticUndo = .manual) -> Bool {
        let wasUnconfirmed = converter.hasUnconfirmedAXEdit(in: execution.focus)
        let hasSelection = (execution.focus.initialSelection?.length ?? 0) > 0
        let operation: CombinedShiftDiagnostic.Operation = wasUnconfirmed ? .undo
            : hasSelection ? .selection : request.reconvert ? .undo : .word
        func performEdit() -> Bool {
            if wasUnconfirmed {
                guard preparedSelection == nil else { return false }
                return converter.reconvert(context: context, execution: execution,
                    inputBarrierIsActive: inputBarrierIsActive)
            } else if hasSelection {
                return converter.convertSelection(context: context, execution: execution,
                    restorePrevious: request.reconvert, inputBarrierIsActive: inputBarrierIsActive,
                    prepared: preparedSelection)
            } else if case .receipt(let receipt) = automaticUndo {
                return converter.undoConfirmedCorrection(receipt, execution: execution,
                    inputBarrierIsActive: inputBarrierIsActive) == .confirmed
            } else if case .staleAutomatic = automaticUndo {
                return false
            } else if request.reconvert {
                guard converter.hasReconversionState else {
                    RuntimeDiagnostics.record(.doubleNoReconversionState); return false
                }
                return converter.reconvert(context: context, execution: execution,
                    inputBarrierIsActive: inputBarrierIsActive)
            } else {
                guard let wordContext = request.wordContext else {
                    RuntimeDiagnostics.record(.doubleMissingWordContext); return false
                }
                guard !request.wordKeys.isEmpty || (!request.prevWordKeys.isEmpty && request.boundaryCount > 0) else {
                    guard fallbackSourceIsCurrent?() == true else {
                        RuntimeDiagnostics.record(.doubleNoBufferOrSelection); return false
                    }
                    return converter.convertVerifiedLastWord(context: wordContext,
                        execution: execution, inputBarrierIsActive: inputBarrierIsActive)
                }
                if convertWholeLine, !request.lineKeys.isEmpty,
                   let source = request.lineSourceLayoutID,
                   let lineContext = contextForSource(source) {
                    return converter.convertLineBuffer(request.lineKeys, context: lineContext,
                        execution: execution, inputBarrierIsActive: inputBarrierIsActive)
                }
                return converter.convert(wordKeys: request.wordKeys, prevWordKeys: request.prevWordKeys,
                    boundaryCount: request.boundaryCount, context: wordContext, execution: execution,
                    inputBarrierIsActive: inputBarrierIsActive)
            }
        }
        let succeeded = performEdit()
        let uncertain = converter.hasUnconfirmedAXEdit(in: execution.focus)
        onDiagnostic?(CombinedShiftDiagnostic(application: application, operation: operation,
            result: succeeded ? .confirmed : uncertain ? .uncertain : .refused))
        if !succeeded { onFailure?(uncertain ? .unconfirmedEdit : .noSafeEdit) }
        return succeeded
    }
}
