import Foundation

/// One button for zsh support: explanation and consent, then the profile line with a
/// backup, then the system access request. Steps that are already done are skipped.
/// Every side effect is a closure, so tests never touch a real profile.
@MainActor
struct ShellOneButtonSetup {
    enum Access: Equatable { case granted, denied, noTerminal }
    enum Outcome: Equatable {
        case cancelled
        case failed
        case done(lineInstalled: Bool, openNewTerminal: Bool, access: Access)
    }

    var lineInstalled: () -> Bool
    var confirm: () -> Bool
    var installLine: () throws -> Void
    var enableBridge: () -> Void
    var terminalAvailable: () -> Bool
    var accessGranted: () -> Bool
    var requestAccess: () async -> Bool

    func run() async -> Outcome {
        let needsLine = !lineInstalled()
        if needsLine {
            guard confirm() else { return .cancelled }
            do { try installLine() } catch { return .failed }
        }
        enableBridge()
        let access: Access
        if accessGranted() {
            access = .granted
        } else if !terminalAvailable() {
            access = .noTerminal
        } else {
            access = await requestAccess() ? .granted : .denied
        }
        return .done(lineInstalled: needsLine, openNewTerminal: needsLine, access: access)
    }
}
