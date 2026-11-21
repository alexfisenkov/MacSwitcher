import ApplicationServices

/// Read-only decision for a second Shift whose live caret moved forward after
/// the first tap. It never reads or writes a field itself: callers pass two
/// consecutive whole-field reads taken under the same input lease.
enum CaretReanchor {
    /// Returns the live range of `original`, ending exactly at the live caret,
    /// or nil when any condition fails. `snapshotSuffix`, when known, is the
    /// text that followed the caret in the snapshot and must follow it now.
    static func range(original: String, snapshotCaret: Int, liveCaret: CFRange,
                      first: NativeFieldObservation?, second: NativeFieldObservation?,
                      revisionUnchanged: Bool, snapshotSuffix: String? = nil) -> CFRange? {
        // (а) no key, click, scroll or process change since the first tap;
        // (б) two consecutive reads agree on value and selection;
        // (в) the live selection is collapsed and forward of the snapshot.
        guard revisionUnchanged, let first, let second, first == second,
              liveCaret.length == 0, first.selectionLength == 0,
              first.caretUTF16Location == liveCaret.location,
              liveCaret.location > snapshotCaret else { return nil }
        let units = Array(first.text.utf16)
        let word = Array(original.utf16)
        let caret = liveCaret.location
        // Formatted (paragraph) coordinates may differ from AX raw offsets.
        guard !units.contains(0x000A), !word.isEmpty, caret <= units.count,
              caret >= word.count else { return nil }
        // (г) exactly the typed original immediately before the live caret;
        // (д) the snapshot's text after the caret is unchanged when known.
        guard Array(units[(caret - word.count)..<caret]) == word else { return nil }
        if let snapshotSuffix, Array(units[caret...]) != Array(snapshotSuffix.utf16) { return nil }
        return CFRange(location: caret - word.count, length: word.count)
    }
}
