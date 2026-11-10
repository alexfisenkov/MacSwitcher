import Darwin
import Foundation

@_silgen_name("flock")
private func shellBrokerFlock(_ fd: Int32, _ operation: Int32) -> Int32

/// Explicitly started local broker. It never starts from module initialization.
/// The application owns focus proof and conversion policy; zsh owns BUFFER.
final class GenericShellEditorBroker: @unchecked Sendable {
    enum BrokerError: Error {
        case unsafeDirectory, socketExists, socketFailure, transientStartup(Int32)
        case noSession, unauthorized, protocolFailure
    }

    static func startupError(for code: Int32) -> BrokerError {
        switch code {
        case EINTR, EAGAIN, ENOBUFS, ENOMEM, EMFILE, ENFILE:
            return .transientStartup(code)
        default:
            return .socketFailure
        }
    }

    struct SessionIdentity: Equatable {
        let pid: Int32
        let tty: String
    }

    struct PruneResult: Equatable {
        let removed: Int
        let remaining: Int
    }

    private final class Connection {
        let fd: Int32
        let pid: Int32
        let tty: String
        let lock = NSLock()
        var pending = Data()
        init(fd: Int32, pid: Int32, tty: String) { self.fd = fd; self.pid = pid; self.tty = tty }
    }

    private let directory: URL
    private let permittedShellPaths: Set<String>
    private let focusProof: GenericShellEditorFocusProof
    private let registryLock = NSLock()
    private var sessions: [Int32: Connection] = [:]
#if DEBUG
    var onPruneSnapshotForTesting: (() -> Void)?
    func registerPeerForTesting(fd: Int32, pid: Int32, tty: String, pending: Data = Data()) {
        let connection = Connection(fd: fd, pid: pid, tty: tty)
        connection.pending = pending
        registryLock.lock()
        sessions[pid] = connection
        registryLock.unlock()
    }
#endif
    private var pruneCursor = 0
    private var listener: Int32 = -1
    private var running = false
    private var socketOwned = false
    private var ownerLockFD: Int32 = -1
    private var ownedSocketIdentity: SocketIdentity?
    private var socketPath: String { directory.appendingPathComponent("editor.sock").path }
    private var lockPath: String { directory.appendingPathComponent("editor.lock").path }

    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    init(directory: URL, permittedShellPaths: Set<String> = ["/bin/zsh"],
         focusProof: GenericShellEditorFocusProof) {
        self.directory = directory
        self.permittedShellPaths = permittedShellPaths
        self.focusProof = focusProof
    }

    func start() throws {
        guard !running else { return }
        try prepareDirectory()
        let lockFD = try acquireOwnerLock()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { let failure = Self.startupError(for: errno); Darwin.close(lockFD); throw failure }
        var boundIdentity: SocketIdentity?
        do {
            try removeProvenOrphanSocket()
            var noSigPipe: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                             socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw Self.startupError(for: errno)
            }
            guard var address = Self.socketAddress(socketPath) else { throw BrokerError.socketFailure }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, Self.addressLength(socketPath))
                }
            }
            guard bound == 0 else { throw Self.startupError(for: errno) }
            boundIdentity = try socketIdentity()
            guard Darwin.chmod(socketPath, 0o600) == 0 else { throw Self.startupError(for: errno) }
            guard try socketIdentity(requirePrivateMode: true) == boundIdentity else {
                throw BrokerError.socketExists
            }
            guard Darwin.listen(fd, 8) == 0 else { throw Self.startupError(for: errno) }
            listener = fd
            socketOwned = true
            ownedSocketIdentity = boundIdentity
            ownerLockFD = lockFD
            running = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
        } catch {
            Darwin.close(fd)
            if let boundIdentity { unlinkIfOwned(boundIdentity) }
            Darwin.close(lockFD)
            throw error
        }
    }

    func stop() {
        registryLock.lock()
        running = false
        let oldListener = listener
        listener = -1
        let shouldUnlink = socketOwned
        let identity = ownedSocketIdentity
        ownedSocketIdentity = nil
        socketOwned = false
        let oldOwnerLock = ownerLockFD
        ownerLockFD = -1
        let oldConnections = Array(sessions.values)
        sessions.removeAll()
        pruneCursor = 0
        registryLock.unlock()
        if oldListener >= 0 { Darwin.close(oldListener) }
        for connection in oldConnections {
            connection.lock.lock()
            Darwin.close(connection.fd)
            connection.lock.unlock()
        }
        if shouldUnlink, let identity { unlinkIfOwned(identity) }
        if oldOwnerLock >= 0 { Darwin.close(oldOwnerLock) }
    }

    /// Metadata only. The caller still needs a fresh focus proof before using
    /// any returned identity; registration alone says nothing about foreground.
    func registeredSessions() -> [SessionIdentity] {
        registryLock.lock(); defer { registryLock.unlock() }
        return sessions.values.map { SessionIdentity(pid: $0.pid, tty: $0.tty) }
    }

    /// A peer is closed only when the application has no buffered bytes and
    /// a nonblocking socket peek returns exact EOF. Positive bytes, EAGAIN and
    /// errors are indeterminate and must remain registered.
    static func peerClosed(pendingBytes: Int, peekCount: Int?) -> Bool {
        pendingBytes == 0 && peekCount == 0
    }

    @discardableResult
    func pruneClosedSessions(limit: Int = 16) -> PruneResult {
        registryLock.lock()
        let peers = Array(sessions.values)
        let count = min(max(0, limit), peers.count)
        let candidates: [Connection]
        if peers.isEmpty {
            candidates = []
            pruneCursor = 0
        } else {
            let start = pruneCursor % peers.count
            candidates = (0..<count).map { peers[(start + $0) % peers.count] }
            pruneCursor = (start + count) % peers.count
        }
        registryLock.unlock()
#if DEBUG
        onPruneSnapshotForTesting?()
#endif
        var removed = 0
        for connection in candidates {
            guard connection.lock.try() else { continue }
            registryLock.lock()
            let isCurrent = sessions[connection.pid] === connection
            registryLock.unlock()
            guard isCurrent else { connection.lock.unlock(); continue }
            var byte: UInt8 = 0
            let count: Int?
            if connection.pending.isEmpty {
                let result = Darwin.recv(connection.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                count = result >= 0 ? result : nil
            } else {
                count = nil
            }
            if Self.peerClosed(pendingBytes: connection.pending.count, peekCount: count) {
                registryLock.lock()
                if sessions[connection.pid] === connection {
                    sessions.removeValue(forKey: connection.pid)
                    Darwin.close(connection.fd)
                    removed += 1
                }
                registryLock.unlock()
            }
            connection.lock.unlock()
        }
        registryLock.lock()
        let remaining = sessions.count
        registryLock.unlock()
        return PruneResult(removed: removed, remaining: remaining)
    }

    /// First Shift: only a session/line token leaves zsh. No BUFFER transfer.
    func prepareFocused(timeout: TimeInterval = 0.25) throws -> GenericShellPreparedHandle {
        pruneClosedSessions()
        let matches = registeredSessions().filter { focusProof.permits(sessionPID: $0.pid, tty: $0.tty) }
        guard matches.count == 1, let chosen = matches.first else { throw BrokerError.noSession }
        let connection = try session(chosen.pid, tty: chosen.tty)
        connection.lock.lock(); defer { connection.lock.unlock() }
        let id = UUID()
        try send("P \(id.uuidString)\n", to: connection.fd)
        guard let reply = readReply(from: connection, requestID: id, kind: "A", timeout: timeout) else {
            throw BrokerError.protocolFailure
        }
        let parts = reply.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, GenericShellEditorWire.validNonce(parts[2]) else {
            throw BrokerError.protocolFailure
        }
        return GenericShellPreparedHandle(sessionPID: chosen.pid, tty: chosen.tty,
            lineNonce: parts[2])
    }

    /// Second Shift: the shell reveals the snapshot only if the prepared line
    /// and selection still match. The app must then compute one bounded CAS.
    func queryPrepared(_ handle: GenericShellPreparedHandle,
                       timeout: TimeInterval = 0.25) throws -> GenericShellEditorSnapshot {
        guard focusProof.permits(sessionPID: handle.sessionPID, tty: handle.tty) else {
            throw BrokerError.unauthorized
        }
        let connection = try session(handle.sessionPID, tty: handle.tty)
        connection.lock.lock(); defer { connection.lock.unlock() }
        let id = UUID()
        try send("Q \(id.uuidString) \(handle.lineNonce)\n", to: connection.fd)
        guard let reply = readReply(from: connection, requestID: id, kind: "S", timeout: timeout),
              let snapshot = GenericShellEditorWire.decodeSnapshot(reply,
                  expectedRequestID: id, sessionPID: handle.sessionPID, tty: handle.tty),
              snapshot.lineNonce == handle.lineNonce else { throw BrokerError.protocolFailure }
        return snapshot
    }

    /// Read only, but still require the caller's fresh foreground tab/TTY proof.
    func query(sessionPID: Int32, tty: String, timeout: TimeInterval = 0.25) throws -> GenericShellEditorSnapshot {
        guard focusProof.permits(sessionPID: sessionPID, tty: tty) else { throw BrokerError.unauthorized }
        let connection = try session(sessionPID, tty: tty)
        connection.lock.lock(); defer { connection.lock.unlock() }
        let id = UUID()
        try send("Q \(id.uuidString)\n", to: connection.fd)
        guard let line = readReply(from: connection, requestID: id, kind: "S", timeout: timeout),
              let snapshot = GenericShellEditorWire.decodeSnapshot(line,
                  expectedRequestID: id, sessionPID: sessionPID, tty: tty) else {
            throw BrokerError.protocolFailure
        }
        return snapshot
    }

    /// One-shot CAS. A missing reply is uncertain; the caller may query state
    /// but must never resubmit this request with a new ID or assume no edit.
    func commit(_ proposal: GenericShellEditorProposal, timeout: TimeInterval = 0.25,
                authorization: @Sendable () -> Bool = { true }) -> GenericShellEditorOutcome {
        let before = proposal.expected
        guard focusProof.permits(sessionPID: before.sessionPID, tty: before.tty),
              let line = GenericShellEditorWire.editLine(proposal),
              let connection = try? session(before.sessionPID, tty: before.tty) else { return .refused(nil) }
        connection.lock.lock(); defer { connection.lock.unlock() }
        guard focusProof.permits(sessionPID: before.sessionPID, tty: before.tty),
              authorization() else {
            return .refused(nil)
        }
        do { try send(line, to: connection.fd) } catch { return .uncertain }
        guard let reply = readReply(from: connection, requestID: proposal.requestID,
                                   kind: "R", timeout: timeout) else { return .uncertain }
        let parts = reply.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 8, parts[0] == "R", parts[1] == proposal.requestID.uuidString,
              GenericShellEditorWire.validNonce(parts[3]),
              let buffer = GenericShellEditorWire.decode(parts[7]),
              let cursor = GenericShellEditorWire.boundedNonnegative(parts[4], maximum: buffer.unicodeScalars.count),
              let mark = GenericShellEditorWire.boundedNonnegative(parts[5], maximum: buffer.unicodeScalars.count),
              let region = GenericShellEditorWire.boundedNonnegative(parts[6], maximum: 2) else { return .uncertain }
        let observed = GenericShellEditorSnapshot(sessionPID: before.sessionPID, tty: before.tty,
            lineNonce: parts[3], buffer: buffer, cursor: cursor, mark: mark, regionActive: region)
        if parts[2] == "applied", parts[3] == before.lineNonce,
           buffer == proposal.replacementBuffer, cursor == proposal.replacementCursor,
           region == 0 { return .confirmed(observed) }
        if parts[2] == "refused" { return .refused(observed) }
        return .uncertain
    }

    private func session(_ pid: Int32, tty: String) throws -> Connection {
        registryLock.lock(); defer { registryLock.unlock() }
        guard running, let connection = sessions[pid], connection.tty == tty else { throw BrokerError.noSession }
        return connection
    }

    private func acquireOwnerLock() throws -> Int32 {
        var fd = Darwin.open(lockPath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        let created = fd >= 0
        if fd < 0, errno == EEXIST { fd = Darwin.open(lockPath, O_RDWR | O_NOFOLLOW) }
        guard fd >= 0 else { throw Self.startupError(for: errno) }
        if created && Darwin.fchmod(fd, 0o600) != 0 {
            Darwin.close(fd)
            throw BrokerError.unsafeDirectory
        }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == Darwin.getuid(),
              (info.st_mode & 0o777) == 0o600,
              shellBrokerFlock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw BrokerError.socketExists
        }
        return fd
    }

    private static func socketAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: bytes.count) { pointer in
                for (index, byte) in bytes.enumerated() { pointer[index] = byte }
            }
        }
        return address
    }

    private static func addressLength(_ path: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8CString.count)
    }

    private func socketIdentity(requirePrivateMode: Bool = false) throws -> SocketIdentity {
        var info = stat()
        guard Darwin.lstat(socketPath, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
              info.st_uid == Darwin.getuid(),
              (!requirePrivateMode || (info.st_mode & 0o777) == 0o600) else {
            throw BrokerError.socketExists
        }
        return SocketIdentity(info)
    }

    private func unlinkIfOwned(_ expected: SocketIdentity) {
        guard let actual = try? socketIdentity(), actual == expected else { return }
        _ = Darwin.unlink(socketPath)
    }

    private func removeProvenOrphanSocket() throws {
        var info = stat()
        if Darwin.lstat(socketPath, &info) != 0 {
            guard errno == ENOENT else { throw BrokerError.socketExists }
            return
        }
        let original = try socketIdentity(requirePrivateMode: true)
        guard var address = Self.socketAddress(socketPath) else { throw BrokerError.socketFailure }
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw Self.startupError(for: errno) }
        defer { Darwin.close(probe) }
        let flags = Darwin.fcntl(probe, F_GETFL)
        guard flags >= 0 else { throw Self.startupError(for: errno) }
        guard Darwin.fcntl(probe, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Self.startupError(for: errno)
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, Self.addressLength(socketPath))
            }
        }
        if status == 0 { throw BrokerError.socketExists }
        let failure = errno
        if failure == ENOENT { return } // another actor removed it; bind will decide
        guard failure == ECONNREFUSED,
              try socketIdentity(requirePrivateMode: true) == original else {
            throw BrokerError.socketExists
        }
        guard Darwin.unlink(socketPath) == 0 else { throw BrokerError.socketExists }
    }

    private func prepareDirectory() throws {
        let path = directory.path
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard Darwin.lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == Darwin.getuid(),
              (info.st_mode & 0o777) == 0o700 else { throw BrokerError.unsafeDirectory }
    }

    private func acceptLoop() {
        while true {
            registryLock.lock()
            let active = running, server = listener
            registryLock.unlock()
            guard active, server >= 0 else { return }
            let fd = Darwin.accept(server, nil, nil)
            guard fd >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.admit(fd) }
        }
    }

    private func admit(_ fd: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0, peerPID: Int32 = 0
        var pidLength = socklen_t(MemoryLayout<Int32>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == Darwin.getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &pidLength) == 0,
              pidLength == MemoryLayout<Int32>.size, peerPID > 0 else { Darwin.close(fd); return }
        var pathBytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(peerPID, &pathBytes, UInt32(pathBytes.count)) > 0,
              let zero = pathBytes.firstIndex(of: 0),
              permittedShellPaths.contains(String(decoding: pathBytes[..<zero].map { UInt8(bitPattern: $0) },
                                                  as: UTF8.self)) else { Darwin.close(fd); return }
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else { Darwin.close(fd); return }
        let provisional = Connection(fd: fd, pid: peerPID, tty: "")
        guard let hello = readLine(from: provisional, timeout: 1.0) else { Darwin.close(fd); return }
        let parts = hello.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "H", parts[1] == "1",
              let tty = GenericShellEditorWire.decode(parts[2]),
              tty.hasPrefix("/dev/tty"), tty.utf8.count <= 128 else { Darwin.close(fd); return }
        let connection = Connection(fd: fd, pid: peerPID, tty: tty)
        registryLock.lock()
        guard running else { registryLock.unlock(); Darwin.close(fd); return }
        let old = sessions.updateValue(connection, forKey: peerPID)
        registryLock.unlock()
        if let old {
            old.lock.lock()
            Darwin.close(old.fd)
            old.lock.unlock()
        }
    }

    private func send(_ line: String, to fd: Int32) throws {
        let bytes = Array(line.utf8)
        guard bytes.count <= GenericShellEditorWire.maxLineUTF8 else { throw BrokerError.protocolFailure }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { pointer in
                Darwin.send(fd, pointer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            guard count > 0 else { throw BrokerError.socketFailure }
            offset += count
        }
    }

    /// A prior edit ACK can arrive after a timeout. Skip its tagged response
    /// while querying state; never interpret it as ACK for another request.
    private func readReply(from connection: Connection, requestID: UUID,
                           kind: String, timeout: TimeInterval) -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        for _ in 0..<8 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, let line = readLine(from: connection, timeout: remaining) else { return nil }
            let prefix = "\(kind) \(requestID.uuidString) "
            if line.hasPrefix(prefix) { return line }
        }
        return nil
    }

    private func readLine(from connection: Connection, timeout: TimeInterval) -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let end = connection.pending.firstIndex(of: 10) {
                let line = connection.pending.prefix(upTo: end)
                connection.pending.removeSubrange(...end)
                return String(data: line, encoding: .utf8)
            }
            guard connection.pending.count < GenericShellEditorWire.maxLineUTF8 else { return nil }
            var descriptor = pollfd(fd: connection.fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(100, (deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            guard Darwin.poll(&descriptor, 1, milliseconds) > 0,
                  descriptor.revents & Int16(POLLIN) != 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.recv(connection.fd, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            connection.pending.append(contentsOf: chunk.prefix(count))
            guard connection.pending.count <= GenericShellEditorWire.maxLineUTF8 else { return nil }
        }
        return nil
    }
}
