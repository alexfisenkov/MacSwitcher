import Foundation

/// Several words in a row typed in the wrong layout, no selection: from the
/// end of the typed line, take whole words while each one is confidently
/// better in the other layout. Two or more such words within the live-write
/// limit become one ordinary word-path edit (equal length, verified editor).
/// Longer runs, or a single word, keep the previous last-word behaviour.
enum MultiWordSpan {
    /// The double Shift request rewritten to cover the whole run, or nil.
    static func request(from request: CombinedShiftRequest, context: CombinedShiftContext,
                        limit: Int = NativeFieldEditPlan.maximumEditUnits,
                        isWrongLayoutWord: ([TypedKey]) -> Bool) -> CombinedShiftRequest? {
        guard !request.reconvert, request.focus?.initialSelection?.length == 0,
              !request.wordKeys.isEmpty,
              let wordContext = request.wordContext,
              wordContext.sourceLayoutID == context.sourceLayoutID,
              request.lineSourceLayoutID == context.sourceLayoutID,
              request.lineKeys.count >= request.wordKeys.count,
              zip(request.lineKeys.suffix(request.wordKeys.count), request.wordKeys).allSatisfy({
                  $0.keyCode == $1.keyCode && $0.shift == $1.shift && $0.caps == $1.caps && $0.char == $1.char
              }),
              let span = keys(request.lineKeys, limit: limit, isWrongLayoutWord: isWrongLayoutWord)
        else { return nil }
        return CombinedShiftRequest(action: request.action, wordContext: wordContext,
            wordKeys: span, prevWordKeys: [], lineKeys: request.lineKeys,
            lineSourceLayoutID: request.lineSourceLayoutID, boundaryCount: 0,
            reconvert: false, inputRevision: request.inputRevision,
            frontProcessID: request.frontProcessID, focus: request.focus)
    }

    /// The trailing keys from the start of the earliest wrong word, or nil when
    /// fewer than two words qualify or the run exceeds `limit` keys.
    static func keys(_ line: [TypedKey], limit: Int,
                     isWrongLayoutWord: ([TypedKey]) -> Bool) -> [TypedKey]? {
        guard let last = line.last, !isSpace(last) else { return nil }
        var words: [Range<Int>] = []
        var end = line.count
        var index = line.count
        while index > 0 {
            index -= 1
            if isSpace(line[index]) {
                if end > index + 1 { words.append((index + 1)..<end) }
                end = index
            }
        }
        if end > 0 { words.append(0..<end) }
        var start: Int?
        var count = 0
        for word in words {
            guard isWrongLayoutWord(Array(line[word])) else { break }
            start = word.lowerBound
            count += 1
        }
        guard count >= 2, let start, line.count - start <= limit else { return nil }
        return Array(line[start...])
    }

    private static func isSpace(_ key: TypedKey) -> Bool { key.char == " " }
}
