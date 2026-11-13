import Foundation

enum GenericShellEditorReconciliation {
    enum Result { case confirmed, unchanged, unknown }

    static func classify(before: GenericShellEditorSnapshot,
                         proposal: GenericShellEditorProposal,
                         observed: GenericShellEditorSnapshot?) -> Result {
        guard let observed,
              observed.sessionPID == before.sessionPID, observed.tty == before.tty,
              observed.lineNonce == before.lineNonce else { return .unknown }
        if observed.buffer == proposal.replacementBuffer,
           observed.cursor == proposal.replacementCursor,
           observed.regionActive == 0 { return .confirmed }
        if observed.buffer == before.buffer, observed.cursor == before.cursor,
           observed.mark == before.mark,
           observed.regionActive == before.regionActive { return .unchanged }
        return .unknown
    }
}
