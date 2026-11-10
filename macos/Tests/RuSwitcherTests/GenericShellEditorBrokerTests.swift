import Darwin
import Foundation
import XCTest
@testable import RuSwitcher

final class GenericShellEditorBrokerTests: XCTestCase {
    func testPeerPruningRequiresExactEOFAndNoPendingBytes() {
        XCTAssertTrue(GenericShellEditorBroker.peerClosed(pendingBytes: 0, peekCount: 0))
        XCTAssertFalse(GenericShellEditorBroker.peerClosed(pendingBytes: 1, peekCount: 0))
        XCTAssertFalse(GenericShellEditorBroker.peerClosed(pendingBytes: 0, peekCount: 1))
        XCTAssertFalse(GenericShellEditorBroker.peerClosed(pendingBytes: 0, peekCount: nil))
    }

    func testStartupRetryErrnosAreClosedAndConservative() {
        for code in [EINTR, EAGAIN, ENOBUFS, ENOMEM, EMFILE, ENFILE] {
            guard case .transientStartup(let actual) = GenericShellEditorBroker.startupError(for: code) else {
                return XCTFail("Expected retryable startup errno")
            }
            XCTAssertEqual(actual, code)
        }
        for code in [EACCES, EPERM, EINVAL, ENAMETOOLONG, EADDRINUSE, ECONNREFUSED, Int32.max] {
            guard case .socketFailure = GenericShellEditorBroker.startupError(for: code) else {
                return XCTFail("Unsafe or unknown startup errno was retried")
            }
        }
    }

    func testPruneSkipsReplacedPeerBeforeSocketPeekAndPreservesPending() throws {
        let folder = directory()
        let broker = GenericShellEditorBroker(directory: folder,
            focusProof: Proof(pid: 42, tty: "/dev/ttys999"))
        try broker.start()
        defer { broker.stop(); try? FileManager.default.removeItem(at: folder) }
        var old = [Int32](repeating: -1, count: 2)
        var replacement = [Int32](repeating: -1, count: 2)
        guard old.withUnsafeMutableBufferPointer({
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!)
        }) == 0 else { return XCTFail("old socketpair unavailable") }
        guard replacement.withUnsafeMutableBufferPointer({
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!)
        }) == 0 else {
            Darwin.close(old[0]); Darwin.close(old[1])
            return XCTFail("replacement socketpair unavailable")
        }
        defer { Darwin.close(old[0]); Darwin.close(replacement[1]) }
        broker.registerPeerForTesting(fd: old[0], pid: 42, tty: "/dev/ttys999")
        Darwin.close(old[1]) // old peer is EOF
        broker.onPruneSnapshotForTesting = {
            broker.registerPeerForTesting(fd: replacement[0], pid: 42,
                tty: "/dev/ttys999", pending: Data([1]))
            broker.onPruneSnapshotForTesting = nil
        }
        let result = broker.pruneClosedSessions()
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.remaining, 1)
        XCTAssertEqual(broker.pruneClosedSessions().remaining, 1) // pending app bytes survive even if peer closes
        Darwin.close(replacement[1])
        replacement[1] = -1
        XCTAssertEqual(broker.pruneClosedSessions().remaining, 1)
    }

    private func directory() -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent("ms-broker-\(UUID())")
    }

    private func bindOrphanSocket(at path: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GenericShellEditorBroker.BrokerError.socketFailure }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw GenericShellEditorBroker.BrokerError.socketFailure
        }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: bytes.count) { pointer in
                for (index, byte) in bytes.enumerated() { pointer[index] = byte }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sa_family_t>.size + bytes.count))
            }
        }
        guard bound == 0, Darwin.chmod(path, 0o600) == 0 else {
            throw GenericShellEditorBroker.BrokerError.socketFailure
        }
    }

    func testOrphanSocketRecoveredAndNormalStopRestart() throws {
        let folder = directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("editor.sock")
        try bindOrphanSocket(at: socket.path) // bound then closed, no listener
        let broker = GenericShellEditorBroker(directory: folder,
            focusProof: Proof(pid: 123, tty: "/dev/ttys999"))
        try broker.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        broker.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        try broker.start()
        broker.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }

    func testSecondBrokerCannotTakeActiveSocketOrOwnerLock() throws {
        let folder = directory()
        let first = GenericShellEditorBroker(directory: folder,
            focusProof: Proof(pid: 123, tty: "/dev/ttys999"))
        let second = GenericShellEditorBroker(directory: folder,
            focusProof: Proof(pid: 123, tty: "/dev/ttys999"))
        try first.start()
        defer { first.stop(); second.stop(); try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("editor.sock")
        XCTAssertThrowsError(try second.start())
        second.stop() // failed starter must not unlink first listener
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        first.stop()
        try second.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
    }

    func testRegularAndSymlinkAtSocketPathArePreserved() throws {
        for symlink in [false, true] {
            let folder = directory()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let socket = folder.appendingPathComponent("editor.sock")
            let regular = folder.appendingPathComponent("regular")
            try Data("synthetic".utf8).write(to: regular)
            if symlink {
                try FileManager.default.createSymbolicLink(at: socket, withDestinationURL: regular)
            } else {
                try Data("synthetic".utf8).write(to: socket)
            }
            let broker = GenericShellEditorBroker(directory: folder,
                focusProof: Proof(pid: 123, tty: "/dev/ttys999"))
            XCTAssertThrowsError(try broker.start())
            broker.stop()
            XCTAssertEqual(try Data(contentsOf: socket), Data("synthetic".utf8))
            if symlink {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: socket.path),
                    regular.path)
            }
        }
    }
    private final class Proof: GenericShellEditorFocusProof, @unchecked Sendable {
        var pid: Int32
        let tty: String
        private let lock = NSLock()
        private var calls = 0
        var blockOnCall: Int?
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        init(pid: Int32, tty: String) { self.pid = pid; self.tty = tty }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func permits(sessionPID: Int32, tty: String) -> Bool {
            lock.lock()
            calls += 1
            let shouldBlock = calls == blockOnCall
            lock.unlock()
            if shouldBlock {
                entered.signal()
                _ = resume.wait(timeout: .now() + 2)
            }
            return sessionPID == pid && tty == self.tty
        }
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: GenericShellEditorOutcome?
        let finished = DispatchSemaphore(value: 0)
        func put(_ outcome: GenericShellEditorOutcome) {
            lock.lock(); stored = outcome; lock.unlock()
            finished.signal()
        }
        var value: GenericShellEditorOutcome? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    func testUntrustedCallerCannotRegisterOrQuery() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ms-broker-\(UUID())")
        let broker = GenericShellEditorBroker(directory: directory,
            focusProof: Proof(pid: 123, tty: "/dev/ttys999"))
        try broker.start()
        defer { broker.stop(); try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("editor.sock")
        let attrs = try FileManager.default.attributesOfItem(atPath: socket.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertThrowsError(try broker.query(sessionPID: 123, tty: "/dev/ttys999"))
        XCTAssertThrowsError(try broker.query(sessionPID: 456, tty: "/dev/ttys999"))
    }

    func testZshPTYRoundTripAndNoCommandExecution() throws {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0,
              let ttyPointer = ttyname(slave) else { return XCTFail("PTY unavailable") }
        let tty = String(cString: ttyPointer)
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ms-broker-\(UUID())")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resource = root.appendingPathComponent("Sources/RuSwitcher/Resources/terminal-zle.zsh")
        let fixture = directory.appendingPathComponent("fixture.zsh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let fixtureSource = """
        unset LC_ALL LC_CTYPE
        export LANG=en_US.UTF-8
        setopt KSH_ARRAYS SH_WORD_SPLIT
        typeset -g _ms_bridge_socket=\(String(reflecting: directory.appendingPathComponent("editor.sock").path))
        source \(String(reflecting: resource.path))
        typeset test_buffer=ghbdtn
        vared -c test_buffer
        """
        try fixtureSource.write(to: fixture, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-dfi", "-c", "source \(fixture.path)"]
        process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let proof = Proof(pid: 0, tty: tty)
        let live = GenericShellEditorBroker(directory: directory, focusProof: proof)
        try live.start()
        try process.run()
        proof.pid = process.processIdentifier
        defer {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            live.stop()
            Darwin.close(master)
            Darwin.close(slave)
            try? FileManager.default.removeItem(at: directory)
        }
        var prepared: GenericShellPreparedHandle?
        for _ in 0..<30 {
            prepared = try? live.prepareFocused(timeout: 0.1)
            if prepared != nil { break }
            usleep(50_000)
        }
        guard let prepared else { return XCTFail("ZLE did not register an active prompt") }
        let before = try live.queryPrepared(prepared)
        XCTAssertEqual(before.buffer, "ghbdtn")
        let proposal = GenericShellEditorProposal(expected: before,
            replacementBuffer: "привет", replacementCursor: 6, requestID: UUID())
        let outcome = live.commit(proposal, timeout: 1.0)
        guard case .confirmed(let after) = outcome else { return XCTFail("No confirmed ZLE CAS: \(outcome)") }
        XCTAssertEqual(after.buffer, "привет")
        XCTAssertEqual(after.cursor, 6)
        let repeated = live.commit(proposal, timeout: 1.0)
        XCTAssertEqual(repeated, .confirmed(after)) // cached outcome; no second write
        XCTAssertEqual(try live.query(sessionPID: process.processIdentifier, tty: tty).buffer, "привет")
        let stale = GenericShellEditorProposal(expected: before,
            replacementBuffer: "другой", replacementCursor: 6, requestID: UUID())
        guard case .refused(let staleState) = live.commit(stale, timeout: 1.0) else {
            return XCTFail("Stale snapshot was not refused")
        }
        XCTAssertEqual(staleState?.buffer, "привет")
        let revoked = GenericShellEditorProposal(expected: after,
            replacementBuffer: "отмена", replacementCursor: 6, requestID: UUID())
        let gate = ShellAuthorizationGate()
        let token = gate.next()
        _ = gate.next() // physical input while a prior focus proof was pending
        guard case .refused = live.commit(revoked, timeout: 1.0,
            authorization: { gate.allows(token) }) else { return XCTFail("Revoked authorization wrote to shell") }
        XCTAssertEqual(try live.query(sessionPID: process.processIdentifier, tty: tty).buffer, "привет")
        let delayed = GenericShellEditorProposal(expected: after,
            replacementBuffer: "поздно", replacementCursor: 6, requestID: UUID())
        let pendingToken = gate.next()
        proof.blockOnCall = proof.callCount + 2 // second proof is immediately before send
        let outcomeBox = OutcomeBox()
        DispatchQueue.global().async {
            outcomeBox.put(live.commit(delayed, timeout: 1.0,
                authorization: { gate.allows(pendingToken) }))
        }
        XCTAssertEqual(proof.entered.wait(timeout: .now() + 2), .success)
        _ = gate.next() // input arrives while final selected-tab proof is delayed
        proof.resume.signal()
        XCTAssertEqual(outcomeBox.finished.wait(timeout: .now() + 2), .success)
        guard case .refused = outcomeBox.value else { return XCTFail("Late revocation wrote to shell") }
        XCTAssertEqual(try live.query(sessionPID: process.processIdentifier, tty: tty).buffer, "привет")
        let slowChecks = GenericShellEditorProposal(expected: after,
            replacementBuffer: "опасно", replacementCursor: 6, requestID: UUID())
        let checkingToken = gate.next()
        let checksEntered = DispatchSemaphore(value: 0)
        let checksResume = DispatchSemaphore(value: 0)
        let checksOutcome = OutcomeBox()
        DispatchQueue.global().async {
            checksOutcome.put(live.commit(slowChecks, timeout: 1.0, authorization: {
                gate.permits(checkingToken) {
                    checksEntered.signal()
                    _ = checksResume.wait(timeout: .now() + 2)
                    return true // models a successful but slow AX/TTY check
                }
            }))
        }
        XCTAssertEqual(checksEntered.wait(timeout: .now() + 2), .success)
        _ = gate.next() // physical input during the slow final authorization
        checksResume.signal()
        XCTAssertEqual(checksOutcome.finished.wait(timeout: .now() + 2), .success)
        guard case .refused = checksOutcome.value else { return XCTFail("Post-AX gate failed to block send") }
        XCTAssertEqual(try live.query(sessionPID: process.processIdentifier, tty: tty).buffer, "привет")
        let sentinel = directory.appendingPathComponent("must-not-execute")
        let command = "touch \(sentinel.path)"
        let inert = GenericShellEditorProposal(expected: after,
            replacementBuffer: command, replacementCursor: command.count, requestID: UUID())
        guard case .confirmed(let inertState) = live.commit(inert, timeout: 1.0) else {
            return XCTFail("Synthetic command remained unsubmitted")
        }
        XCTAssertEqual(inertState.buffer, command)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        let longLine = String(repeating: "a", count: 8192)
        let fragmented = GenericShellEditorProposal(expected: inertState,
            replacementBuffer: longLine, replacementCursor: longLine.count, requestID: UUID())
        guard case .confirmed(let largeState) = live.commit(fragmented, timeout: 2.0) else {
            return XCTFail("Fragmented socket frame did not commit")
        }
        XCTAssertEqual(largeState.buffer, longLine)
        // Once zsh closes, the off-input prune must remove the stale peer
        // before any selected-tab focus proof is attempted.
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        for _ in 0..<20 where !live.registeredSessions().isEmpty {
            _ = live.pruneClosedSessions()
            usleep(50_000)
        }
        XCTAssertTrue(live.registeredSessions().isEmpty)
        let proofCount = proof.callCount
        XCTAssertThrowsError(try live.prepareFocused(timeout: 0.1))
        XCTAssertEqual(proof.callCount, proofCount)
    }

    func testZLENaturalCursorUsesUnicodeScalarOffsets() throws {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0,
              let ttyPointer = ttyname(slave) else { return XCTFail("PTY unavailable") }
        let tty = String(cString: ttyPointer)
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ms-broker-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resource = root.appendingPathComponent("Sources/RuSwitcher/Resources/terminal-zle.zsh")
        let fixture = directory.appendingPathComponent("unicode.zsh")
        let input = "👩‍💻 е\u{301} ghbdtn"
        let content = """
        unset LC_ALL LC_CTYPE
        export LANG=en_US.UTF-8
        typeset -g _ms_bridge_socket=\(String(reflecting: directory.appendingPathComponent("editor.sock").path))
        source \(String(reflecting: resource.path))
        typeset test_buffer='\(input)'
        vared -c test_buffer
        """
        try content.write(to: fixture, atomically: true, encoding: .utf8)
        let proof = Proof(pid: 0, tty: tty)
        let broker = GenericShellEditorBroker(directory: directory, focusProof: proof)
        try broker.start()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-dfi", "-c", "source \(fixture.path)"]
        process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        try process.run()
        proof.pid = process.processIdentifier
        defer {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            broker.stop()
            Darwin.close(master)
            Darwin.close(slave)
            try? FileManager.default.removeItem(at: directory)
        }
        var prepared: GenericShellPreparedHandle?
        for _ in 0..<30 {
            prepared = try? broker.prepareFocused(timeout: 0.1)
            if prepared != nil { break }
            usleep(50_000)
        }
        let handle = try XCTUnwrap(prepared)
        let snapshot = try broker.queryPrepared(handle)
        XCTAssertEqual(snapshot.buffer, input)
        XCTAssertEqual(snapshot.cursor, input.unicodeScalars.count)
        XCTAssertNotEqual(snapshot.cursor, input.count)
    }
}
