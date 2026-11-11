import AppKit
import ApplicationServices
import Darwin
import XCTest
@testable import RuSwitcher

/// Own PTY/session fixture. Python is spawned directly as the process under
/// test; it never launches a shell or touches the user's terminal/profile.
private final class ForegroundPTYFixture {
    private static let script = #"""
import os, pty, signal, sys
def stop(_signal, _frame):
    raise SystemExit
signal.signal(signal.SIGTERM, stop)
command_read, command_write = os.pipe()
reply_read, reply_write = os.pipe()
shell, master = pty.fork()
if shell == 0:
    os.close(command_write)
    os.close(reply_read)
    child = None
    try:
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
    finally:
        if child:
            os.kill(child, signal.SIGKILL)
    os._exit(0)
os.close(command_read)
os.close(reply_write)
background = None
try:
    print(os.read(reply_read, 256).decode().strip(), flush=True)
    for command in sys.stdin:
        if command.strip() == 'background':
            os.write(command_write, b'b')
            background = int(os.read(reply_read, 256).decode().strip())
            print(background, flush=True)
finally:
    if background:
        os.kill(background, signal.SIGKILL)
    os.kill(shell, signal.SIGTERM)
    os.waitpid(shell, 0)
    os.close(master)
"""#

    let shellPID: pid_t
    let tty: String
    private let process: Process
    private let input: Pipe
    private let output: Pipe

    init() throws {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", Self.script]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let parts: [Substring]
        let validatedPID: pid_t
        do {
            parts = try Self.readReply(from: output).split(separator: " ")
            guard parts.count == 2, let pid = pid_t(parts[0]), pid > 0,
                  parts[1].hasPrefix("/dev/ttys") else { throw POSIXError(.EIO) }
            validatedPID = pid
        } catch {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        self.process = process
        self.input = input
        self.output = output
        shellPID = validatedPID
        tty = String(parts[1])
    }

    func moveShellToBackground() throws {
        try input.fileHandleForWriting.write(contentsOf: Data("background\n".utf8))
        guard let pid = pid_t(try Self.readReply(from: output)), pid > 0 else {
            throw POSIXError(.EIO)
        }
    }

    private static func readReply(from output: Pipe) throws -> String {
        let fd = output.fileHandleForReading.fileDescriptor
        var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&waiting, 1, 3_000) == 1, waiting.revents & Int16(POLLIN) != 0 else {
            throw POSIXError(.ETIMEDOUT)
        }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, let line = String(bytes: bytes[..<count], encoding: .utf8)?.split(separator: "\n").first else {
            throw POSIXError(.EIO)
        }
        return String(line)
    }

    deinit {
        input.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

final class ScriptableSelectedTTYTests: XCTestCase {
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
