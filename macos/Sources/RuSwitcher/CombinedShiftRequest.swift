/// Event-time snapshot. Nothing reads the new active source or mutable key buffers later.
struct CombinedShiftRequest: Sendable {
    let action: CombinedShiftGesture.Action
    let wordContext: CombinedShiftContext?
    let wordKeys: [TypedKey]
    let prevWordKeys: [TypedKey]
    let lineKeys: [TypedKey]
    let lineSourceLayoutID: String?
    let boundaryCount: Int
    let reconvert: Bool
    let inputRevision: UInt64
    let frontProcessID: Int32
    let focus: CombinedShiftFocus?
}
