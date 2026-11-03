/// An explicit switch may supersede an older unresolved source only after the
/// intended layout is independently observed. A refused or delayed switch
/// leaves the pending gate intact.
@MainActor
enum ExplicitSourceSelectionRecovery {
    static func switchOpposite(intendedTargetID: String?, switchSource: () -> Void,
                               observeSource: () -> String,
                               confirm: (String, String) -> Void) {
        switchSource()
        guard let intendedTargetID, !intendedTargetID.isEmpty else { return }
        let observedSourceID = observeSource()
        guard observedSourceID == intendedTargetID else { return }
        confirm(intendedTargetID, observedSourceID)
    }
}
