import AppKit
import ApplicationServices
import Darwin
import XCTest
@testable import RuSwitcher

/// Own PTY/session fixture. Python is spawned directly as the process under
/// test; it never launches a shell or touches the user's terminal/profile.
private final class ForegroundPTYFixture {
    private static let script = #"""
import os, pty, signal, sys, time
def stop(_signal, _frame):
    raise SystemExit
signal.signal(signal.SIGTERM, stop)
mode = sys.argv[1] if len(sys.argv) > 1 else ''
if mode == 'delayed-start':
    time.sleep(3.2)
if mode in ('hot-stdout', 'hot-stderr'):
    stream = 1 if mode == 'hot-stdout' else 2
    while True:
        os.write(stream, b'x' * 128)
print('python-ready', flush=True)
command_read, command_write = os.pipe()
reply_read, reply_write = os.pipe()
shell, master = pty.fork()
if shell == 0:
    os.close(command_write)
    os.close(reply_read)
    child = None
    try:
        if mode in ('child-error', 'child-hang', 'child-stubborn'):
            if mode == 'child-error':
                raise RuntimeError('injected PTY child error')
            if mode == 'child-stubborn':
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.pause()
        os.write(reply_write, f'{os.getpid()} {os.ttyname(0)}\n'.encode())
        if os.read(command_read, 1) == b'b':
            child = os.fork()
            if child == 0:
                os.setpgid(0, 0)
                signal.pause()
                os._exit(0)
            os.setpgid(child, child)
            os.tcsetpgrp(0, child)
            os.write(reply_write, f'{child}\n'.encode())
        signal.pause()
    except Exception as exc:
        os.write(reply_write, f'child-error {type(exc).__name__}: {exc}\n'.encode())
        raise
    finally:
        if child and child > 0:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(child, 0)
            except ChildProcessError:
                pass
    os._exit(0)
os.close(command_read)
os.close(reply_write)
print(f'spawned {shell}', flush=True)
background = None
try:
    greeting = os.read(reply_read, 256)
    if not greeting:
        raise RuntimeError('PTY child exited before ready')
    print(greeting.decode().strip(), flush=True)
    for command in sys.stdin:
        if command.strip() == 'background':
            os.write(command_write, b'b')
            background = int(os.read(reply_read, 256).decode().strip())
            print(background, flush=True)
finally:
    try:
        os.kill(shell, signal.SIGTERM)
    except ProcessLookupError:
        pass
    os.waitpid(shell, 0)
    os.close(master)
"""#

    let shellPID: pid_t
    let tty: String
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let stderr: Pipe
    private let terminated: DispatchSemaphore
    private var pendingOutput = Data()
    private var diagnostics = Data()
    private var backgroundPID: pid_t?

    private struct Failure: Error, CustomStringConvertible {
        let phase: String
        let reason: String
        let diagnostics: String
        let exitStatus: String

        var description: String {
            "PTY fixture \(phase): \(reason); process \(exitStatus); stderr: \(diagnostics)"
        }
    }

    init(mode: String = "", timeout: TimeInterval = 8,
         onSpawn: ((pid_t) -> Void)? = nil) throws {
        let process = Process()
        let input = Pipe(), output = Pipe(), stderr = Pipe()
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", Self.script, mode]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = stderr
        try process.run()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var pendingOutput = Data(), diagnostics = Data()
        var spawnedPID: pid_t?
        let parts: [Substring]
        let validatedPID: pid_t
        do {
            guard try Self.readReply(from: output, stderr: stderr, process: process,
                                     pending: &pendingOutput, diagnostics: &diagnostics,
                                     deadline: deadline, phase: "Python startup") == "python-ready" else {
                throw POSIXError(.EIO)
            }
            let spawned = try Self.readReply(from: output, stderr: stderr, process: process,
                                             pending: &pendingOutput, diagnostics: &diagnostics,
                                             deadline: deadline, phase: "PTY fork").split(separator: " ")
            guard spawned.count == 2, spawned[0] == "spawned",
                  let pid = pid_t(spawned[1]), pid > 0 else { throw POSIXError(.EIO) }
            spawnedPID = pid
            onSpawn?(pid)
            let childReply = try Self.readReply(from: output, stderr: stderr, process: process,
                                                pending: &pendingOutput, diagnostics: &diagnostics,
                                                deadline: deadline, phase: "PTY child ready")
            if childReply.hasPrefix("child-error ") {
                throw Self.failure(phase: "PTY child ready", reason: childReply,
                                   process: process, diagnostics: diagnostics)
            }
            parts = childReply.split(separator: " ")
            guard parts.count == 2, let pid = pid_t(parts[0]), pid > 0,
                  pid == spawnedPID, parts[1].hasPrefix("/dev/ttys") else { throw POSIXError(.EIO) }
            validatedPID = pid
        } catch {
            Self.cleanup(process: process, input: input, terminated: terminated,
                         shellPID: spawnedPID, backgroundPID: nil)
            throw error
        }
        self.process = process
        self.input = input
        self.output = output
        self.stderr = stderr
        self.terminated = terminated
        self.pendingOutput = pendingOutput
        self.diagnostics = diagnostics
        shellPID = validatedPID
        tty = String(parts[1])
    }

    func moveShellToBackground() throws {
        try input.fileHandleForWriting.write(contentsOf: Data("background\n".utf8))
        let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
        guard let pid = pid_t(try Self.readReply(from: output, stderr: stderr, process: process,
                                                pending: &pendingOutput, diagnostics: &diagnostics,
                                                deadline: deadline, phase: "background job")), pid > 0 else {
            throw POSIXError(.EIO)
        }
        backgroundPID = pid
    }

    private static func readReply(from output: Pipe, stderr: Pipe, process: Process,
                                  pending: inout Data, diagnostics: inout Data,
                                  deadline: UInt64, phase: String) throws -> String {
        var stderrOpen = true
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline {
                throw failure(phase: phase, reason: "deadline exceeded",
                              process: process, diagnostics: diagnostics)
            }
            if pending.count > 256 {
                throw failure(phase: phase, reason: "reply exceeds 256 bytes",
                              process: process, diagnostics: diagnostics)
            }
            if let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard let value = String(data: line, encoding: .utf8) else { throw POSIXError(.EIO) }
                return value
            }
            let remaining = Int32(min((deadline - now + 999_999) / 1_000_000,
                                      UInt64(Int32.max)))
            var descriptors = [pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                      events: Int16(POLLIN | POLLHUP), revents: 0),
                               pollfd(fd: stderrOpen ? stderr.fileHandleForReading.fileDescriptor : -1,
                                      events: Int16(POLLIN | POLLHUP), revents: 0)]
            let result = poll(&descriptors, nfds_t(descriptors.count), remaining)
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if descriptors.contains(where: { $0.revents & Int16(POLLERR | POLLNVAL) != 0 }) {
                throw failure(phase: phase, reason: "pipe poll error",
                              process: process, diagnostics: diagnostics)
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = read(descriptors[1].fd, &bytes, bytes.count)
                if count > 0, diagnostics.count < 4096 {
                    diagnostics.append(contentsOf: bytes[..<min(count, 4096 - diagnostics.count)])
                }
            }
            if descriptors[1].revents & Int16(POLLHUP) != 0,
               descriptors[1].revents & Int16(POLLIN) == 0 { stderrOpen = false }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                var bytes = [UInt8](repeating: 0, count: 256)
                let count = read(descriptors[0].fd, &bytes, bytes.count)
                if count > 0 {
                    pending.append(contentsOf: bytes[..<count])
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw failure(phase: phase, reason: "stdout closed before reply",
                              process: process, diagnostics: diagnostics)
            }
            if result == 0 {
                throw failure(phase: phase, reason: "deadline exceeded",
                              process: process, diagnostics: diagnostics)
            }
        }
    }

    private static func failure(phase: String, reason: String, process: Process,
                                diagnostics: Data) -> Failure {
        let status = process.isRunning ? "still running" : "exited (status \(process.terminationStatus))"
        return Failure(phase: phase, reason: reason,
                       diagnostics: String(decoding: diagnostics, as: UTF8.self), exitStatus: status)
    }

    private static func cleanup(process: Process, input: Pipe, terminated: DispatchSemaphore,
                                shellPID: pid_t?, backgroundPID: pid_t?) {
        input.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
        if terminated.wait(timeout: .now() + 1) == .timedOut {
            if let backgroundPID, let shellPID, isChild(backgroundPID, of: shellPID) {
                _ = Darwin.kill(backgroundPID, SIGKILL)
            }
            if let shellPID, isChild(shellPID, of: process.processIdentifier) {
                _ = Darwin.kill(shellPID, SIGKILL)
            }
            if terminated.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }

    private static func isChild(_ pid: pid_t, of parent: pid_t) -> Bool {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        return sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 &&
            size == MemoryLayout<kinfo_proc>.stride && info.kp_eproc.e_ppid == parent
    }

    deinit {
        Self.cleanup(process: process, input: input, terminated: terminated,
                     shellPID: shellPID, backgroundPID: backgroundPID)
    }
}

final class ScriptableSelectedTTYTests: XCTestCase {
    func testPTYFixtureAcceptsDelayedInterpreterStartup() throws {
        let fixture = try ForegroundPTYFixture(mode: "delayed-start")
        XCTAssertTrue(ScriptableShellFocusProof.shellIsForeground(fixture.shellPID, tty: fixture.tty))
    }

    func testPTYFixtureBoundsUnterminatedHotStdout() {
        XCTAssertThrowsError(try ForegroundPTYFixture(mode: "hot-stdout", timeout: 0.5)) { error in
            XCTAssertTrue(String(describing: error).contains("reply exceeds 256 bytes"))
        }
    }

    func testPTYFixtureDeadlineSurvivesHotStderr() {
        XCTAssertThrowsError(try ForegroundPTYFixture(mode: "hot-stderr", timeout: 0.5)) { error in
            XCTAssertTrue(String(describing: error).contains("Python startup: deadline exceeded"))
        }
    }

    func testPTYFixtureReportsChildErrorAndReapsIt() {
        var childPID: pid_t = 0
        XCTAssertThrowsError(try ForegroundPTYFixture(mode: "child-error", onSpawn: { childPID = $0 })) { error in
            XCTAssertTrue(String(describing: error).contains("injected PTY child error"))
        }
        XCTAssertGreaterThan(childPID, 0)
        if childPID > 0 {
            XCTAssertEqual(Darwin.kill(childPID, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testPTYFixtureTimeoutReapsStalledChild() {
        var childPID: pid_t = 0
        XCTAssertThrowsError(try ForegroundPTYFixture(mode: "child-hang", timeout: 0.5,
                                                      onSpawn: { childPID = $0 })) { error in
            XCTAssertTrue(String(describing: error).contains("PTY child ready: deadline exceeded"))
        }
        XCTAssertGreaterThan(childPID, 0)
        if childPID > 0 {
            XCTAssertEqual(Darwin.kill(childPID, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testPTYFixtureForcedChildCleanupLetsPythonReapBeforeExit() {
        var childPID: pid_t = 0
        XCTAssertThrowsError(try ForegroundPTYFixture(mode: "child-stubborn", timeout: 0.5,
                                                      onSpawn: { childPID = $0 })) { error in
            XCTAssertTrue(String(describing: error).contains("PTY child ready: deadline exceeded"))
        }
        XCTAssertGreaterThan(childPID, 0)
        if childPID > 0 {
            XCTAssertEqual(Darwin.kill(childPID, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testForegroundProofUsesShellControllingTTYFromNonControllingParent() throws {
        let fixture = try ForegroundPTYFixture()
        let selectedFD = Darwin.open(fixture.tty, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(selectedFD, 0)
        if selectedFD >= 0 {
            let foreground = Darwin.tcgetpgrp(selectedFD)
            let failure = errno
            Darwin.close(selectedFD)
            XCTAssertEqual(foreground, -1)
            XCTAssertEqual(failure, ENOTTY)
        }
        XCTAssertTrue(ScriptableShellFocusProof.shellIsForeground(fixture.shellPID, tty: fixture.tty))
        XCTAssertFalse(ScriptableShellFocusProof.shellIsForeground(Int32.max, tty: fixture.tty))

        var otherMaster: Int32 = -1, otherSlave: Int32 = -1
        var otherName = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(openpty(&otherMaster, &otherSlave, &otherName, nil, nil), 0)
        defer { if otherMaster >= 0 { close(otherMaster) }; if otherSlave >= 0 { close(otherSlave) } }
        XCTAssertFalse(ScriptableShellFocusProof.shellIsForeground(fixture.shellPID,
            tty: String(decoding: otherName.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)),
                as: UTF8.self)))

        try fixture.moveShellToBackground()
        XCTAssertFalse(ScriptableShellFocusProof.shellIsForeground(fixture.shellPID, tty: fixture.tty))
    }

    private final class MockExecutor: ReadOnlyAppleEventExecutor {
        var permission: OSStatus = noErr
        var readCodes: [OSType] = []
        var tty = "/dev/ttys001"
        var id: Int32 = 71
        var boundsDescriptor: NSAppleEventDescriptor?
        var boundsDescriptorAfterFirstRead: NSAppleEventDescriptor?
        var flipTTYAfterTwoReads = false
        private var ttyReads = 0
        private var boundsReads = 0
        func preflight(pid: Int32) -> OSStatus { permission }
        func read(pid: Int32, object: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
            var objectRecord = object.aeDesc!.pointee
            var rawKey = AEDesc()
            guard AEGetParamDesc(&objectRecord, AEKeyword(keyAEKeyData), DescType(typeWildCard), &rawKey) == noErr else {
                return nil
            }
            let key = NSAppleEventDescriptor(aeDescNoCopy: &rawKey)
            let code = key.typeCodeValue
            readCodes.append(code)
            switch code {
            case ScriptableSelectedTTYCapability.terminalSDEF.frontmostProperty:
                return .init(boolean: true)
            case ScriptableSelectedTTYCapability.terminalSDEF.windowIDProperty:
                return .init(int32: id)
            case ScriptableSelectedTTYCapability.terminalSDEF.ttyProperty:
                ttyReads += 1
                return .init(string: flipTTYAfterTwoReads && ttyReads > 2
                    ? "/dev/ttys002" : tty)
            case ScriptableSelectedTTYCapability.terminalSDEF.boundsProperty:
                boundsReads += 1
                if boundsReads > 1, let changed = boundsDescriptorAfterFirstRead { return changed }
                return boundsDescriptor ?? .init(descriptorType: OSType(typeQDRectangle),
                    data: Data([0, 20, 0, 30, 1, 20, 2, 30]))
            default: return nil
            }
        }
    }

    func testReadOnlyPropertyChainReturnsStableSelectedTTY() throws {
        let executor = MockExecutor()
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        let result = try reader.observe(pid: 123)
        XCTAssertEqual(result.tty, "/dev/ttys001")
        XCTAssertEqual(result.windowID, 71)
        XCTAssertTrue(result.windowBoundsCandidates.contains(CGRect(x: 30, y: 20, width: 512, height: 256)))
        XCTAssertEqual(executor.readCodes.count, 7)
        XCTAssertEqual(executor.readCodes.filter { $0 == ScriptableSelectedTTYCapability.terminalSDEF.ttyProperty }.count, 2)
    }

    func testPreflightConsentAndChangedSelectedTabRefuseWithoutEvent() {
        let executor = MockExecutor()
        executor.permission = OSStatus(errAEEventWouldRequireUserConsent)
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        XCTAssertThrowsError(try reader.observe(pid: 123))
        XCTAssertTrue(executor.readCodes.isEmpty)
        executor.permission = noErr
        executor.tty = "not-a-device"
        XCTAssertThrowsError(try reader.observe(pid: 123))
    }

    func testRectangleRejectsMalformedBounds() {
        XCTAssertNil(ScriptableSelectedTTYReader.qdRect(Data([0, 1])))
        XCTAssertNil(ScriptableSelectedTTYReader.qdRect(Data(repeating: 0, count: 8)))
    }

    func testEndianCandidatesRequireUniqueAXWitness() {
        let expected = CGRect(x: 30, y: 20, width: 512, height: 256)
        let executor = MockExecutor()
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        for raw in [Data([0, 20, 0, 30, 1, 20, 2, 30]),
                    Data([20, 0, 30, 0, 20, 1, 30, 2])] {
            executor.boundsDescriptor = NSAppleEventDescriptor(descriptorType: OSType(typeQDRectangle), data: raw)
            let proof = ScriptableShellFocusProof(readerForPID: { _ in reader },
                frontmostPID: { 123 }, axValidator: { _, rect in rect == expected },
                foregroundValidator: { _, _ in true })
            XCTAssertTrue(proof.permits(sessionPID: 456, tty: "/dev/ttys001"))
            let ambiguous = ScriptableShellFocusProof(readerForPID: { _ in reader },
                frontmostPID: { 123 }, axValidator: { _, _ in true },
                foregroundValidator: { _, _ in true })
            XCTAssertFalse(ambiguous.permits(sessionPID: 456, tty: "/dev/ttys001"))
            let noMatch = ScriptableShellFocusProof(readerForPID: { _ in reader },
                frontmostPID: { 123 }, axValidator: { _, _ in false },
                foregroundValidator: { _, _ in true })
            XCTAssertFalse(noMatch.permits(sessionPID: 456, tty: "/dev/ttys001"))
        }
    }

    func testSignedNegativeQuickDrawCoordinates() {
        let raw = Data([0xFF, 0xEC, 0xFF, 0xE2, 0x00, 0xC8, 0x01, 0x2C])
        let expected = CGRect(x: -30, y: -20, width: 330, height: 220)
        XCTAssertEqual(ScriptableSelectedTTYReader.qdRect(raw), expected)
        let littleEndian = Data([0xEC, 0xFF, 0xE2, 0xFF, 0xC8, 0x00, 0x2C, 0x01])
        XCTAssertTrue(ScriptableSelectedTTYReader.qdRectCandidates(littleEndian).contains(expected))
    }

    func testChangedRawBoundsAfterAXWitnessRefuses() {
        let executor = MockExecutor()
        executor.boundsDescriptorAfterFirstRead = NSAppleEventDescriptor(
            descriptorType: OSType(typeQDRectangle),
            data: Data([20, 0, 30, 0, 20, 1, 30, 2]))
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        let proof = ScriptableShellFocusProof(readerForPID: { _ in reader },
            frontmostPID: { 123 }, axValidator: { _, rect in
                rect == CGRect(x: 30, y: 20, width: 512, height: 256)
            }, foregroundValidator: { _, _ in true })
        XCTAssertFalse(proof.permits(sessionPID: 456, tty: "/dev/ttys001"))
    }

    func testBoundsReplyMustBeTypedQDRectangle() {
        let raw = Data([0, 20, 0, 30, 1, 20, 2, 30])
        let executor = MockExecutor()
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        executor.boundsDescriptor = NSAppleEventDescriptor(descriptorType: OSType(0x64617461), data: raw)
        XCTAssertThrowsError(try reader.observe(pid: 123))
        let list = NSAppleEventDescriptor.list()
        for (index, value) in [30, 20, 542, 276].enumerated() {
            list.insert(NSAppleEventDescriptor(int32: Int32(value)), at: index + 1)
        }
        executor.boundsDescriptor = list
        XCTAssertThrowsError(try reader.observe(pid: 123))
    }

    func testFocusProofRefusesTabSwitchAfterAXValidation() {
        let executor = MockExecutor()
        executor.flipTTYAfterTwoReads = true
        let reader = ScriptableSelectedTTYReader(capability: .terminalSDEF, executor: executor)
        let proof = ScriptableShellFocusProof(readerForPID: { _ in reader },
            frontmostPID: { 123 }, axValidator: { _, rect in
                rect == CGRect(x: 30, y: 20, width: 512, height: 256)
            },
            foregroundValidator: { _, _ in true })
        XCTAssertFalse(proof.permits(sessionPID: 456, tty: "/dev/ttys001"))
        XCTAssertEqual(executor.readCodes.filter {
            $0 == ScriptableSelectedTTYCapability.terminalSDEF.ttyProperty
        }.count, 4)
    }

    func testCapabilityDiscoveryUsesSDEFPropertiesRatherThanAppName() throws {
        let file = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.sdef")
        let data = try Data(contentsOf: file)
        let found = try XCTUnwrap(SelectedTTYCapabilityDiscovery.parse(data))
        XCTAssertEqual(found.windowClass, ScriptableSelectedTTYCapability.terminalSDEF.windowClass)
        XCTAssertEqual(found.selectedTabProperty, ScriptableSelectedTTYCapability.terminalSDEF.selectedTabProperty)
        XCTAssertEqual(found.ttyProperty, ScriptableSelectedTTYCapability.terminalSDEF.ttyProperty)
        let unsupported = Data("<dictionary><class name='window' code='cwin'/></dictionary>".utf8)
        XCTAssertNil(SelectedTTYCapabilityDiscovery.parse(unsupported))
    }
}
