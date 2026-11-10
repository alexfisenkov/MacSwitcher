import Foundation

/// Physical input revokes a pending shell edit before the main actor wakes.
final class ShellAuthorizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func allows(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
    }

    func permits(_ token: UInt64, after checks: () -> Bool) -> Bool {
        allows(token) && checks() && allows(token)
    }
}
