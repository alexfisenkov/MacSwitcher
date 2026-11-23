import XCTest
@testable import RuSwitcher

@MainActor
final class ShellOneButtonSetupTests: XCTestCase {
    private final class Log { var calls: [String] = [] }

    private struct Failure: Error {}

    private func setup(_ log: Log, installed: Bool = false, agrees: Bool = true, installFails: Bool = false,
                       terminal: Bool = true, granted: Bool = false, requestResult: Bool = true)
        -> ShellOneButtonSetup {
        ShellOneButtonSetup(
            lineInstalled: { installed },
            confirm: { log.calls.append("confirm"); return agrees },
            installLine: { log.calls.append("install"); if installFails { throw Failure() } },
            enableBridge: { log.calls.append("enable") },
            terminalAvailable: { terminal },
            accessGranted: { granted },
            requestAccess: { log.calls.append("request"); return requestResult })
    }

    func testGhosttyIsAKnownTerminal() {
        XCTAssertTrue(AutoSwitchPolicy.isTerminalApp("com.mitchellh.ghostty"))
        XCTAssertTrue(AutoSwitchPolicy.isTerminalApp("com.apple.Terminal"))
        XCTAssertFalse(AutoSwitchPolicy.isTerminalApp("com.apple.TextEdit"))
    }

    func testFreshSetupAsksOnceInstallsThenRequestsAccess() async {
        let log = Log()
        let outcome = await setup(log).run()
        XCTAssertEqual(log.calls, ["confirm", "install", "enable", "request"])
        XCTAssertEqual(outcome, .done(lineInstalled: true, openNewTerminal: true, access: .granted))
    }

    func testDecliningConsentChangesNothing() async {
        let log = Log()
        let outcome = await setup(log, agrees: false).run()
        XCTAssertEqual(log.calls, ["confirm"])
        XCTAssertEqual(outcome, .cancelled)
    }

    func testFailedInstallStopsBeforeEnablingAndRequesting() async {
        let log = Log()
        let outcome = await setup(log, installFails: true).run()
        XCTAssertEqual(log.calls, ["confirm", "install"])
        XCTAssertEqual(outcome, .failed)
    }

    func testEverythingAlreadyDoneRepeatsNoStep() async {
        let log = Log()
        let outcome = await setup(log, installed: true, granted: true).run()
        XCTAssertEqual(log.calls, ["enable"])
        XCTAssertEqual(outcome, .done(lineInstalled: false, openNewTerminal: false, access: .granted))
    }

    func testInstalledLineSkipsConsentButStillRequestsMissingAccess() async {
        let log = Log()
        let outcome = await setup(log, installed: true).run()
        XCTAssertEqual(log.calls, ["enable", "request"])
        XCTAssertEqual(outcome, .done(lineInstalled: false, openNewTerminal: false, access: .granted))
    }

    func testNoTerminalRunningSkipsTheSystemRequest() async {
        let log = Log()
        let outcome = await setup(log, terminal: false).run()
        XCTAssertEqual(log.calls, ["confirm", "install", "enable"])
        XCTAssertEqual(outcome, .done(lineInstalled: true, openNewTerminal: true, access: .noTerminal))
    }

    func testDeniedSystemRequestIsReported() async {
        let log = Log()
        let outcome = await setup(log, installed: true, requestResult: false).run()
        XCTAssertEqual(outcome, .done(lineInstalled: false, openNewTerminal: false, access: .denied))
    }
}
