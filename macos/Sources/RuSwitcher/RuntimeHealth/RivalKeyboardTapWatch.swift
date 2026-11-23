import AppKit
import CoreGraphics

enum RivalTapState: Equatable {
    case none
    /// The program name is for the one-time hint to the person only; it never reaches a log.
    case active(programName: String?)
}

/// Looks for another program holding an active, system-wide keyboard tap, which can
/// swallow or reorder our events. Idea from Keyboop's rival-tap watch (MIT), see NOTICE.md;
/// the code is written for this project. Runs inside the existing two-second health poll.
final class RivalKeyboardTapWatch {
    struct TapSnapshot {
        let processID: pid_t
        let enabled: Bool
        let isActiveFilter: Bool
        let targetProcessID: pid_t
        let location: CGEventTapLocation
        let eventMask: CGEventMask
        let executablePath: String?
        var displayName: String? = nil
    }

    static let cacheInterval: TimeInterval = 5
    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/"]

    private let source: () -> RivalTapState
    private let now: () -> TimeInterval
    private let record: (RuntimeDiagnosticEvent) -> Void
    private var cached: (state: RivalTapState, at: TimeInterval)?
    private var wasActive = false
    private var hintShown = false

    init(source: @escaping () -> RivalTapState = RivalKeyboardTapWatch.liveState,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         record: @escaping (RuntimeDiagnosticEvent) -> Void = { RuntimeDiagnostics.record($0) }) {
        self.source = source
        self.now = now
        self.record = record
    }

    /// Cached for five seconds. Writes `rivalKeyboardTapActive` each time a rival appears.
    func scan() -> RivalTapState {
        let current = now()
        if let cached, current >= cached.at, current - cached.at < Self.cacheInterval { return cached.state }
        let state = source()
        cached = (state, current)
        let active = state != .none
        if active && !wasActive { record(.rivalKeyboardTapActive) }
        wasActive = active
        return state
    }

    /// The program name for the hint, or `nil` once the hint has been given in this launch.
    /// An empty string means a rival exists but its name is unknown.
    func takeHint(for state: RivalTapState) -> String? {
        guard case .active(let name) = state, !hintShown else { return nil }
        hintShown = true
        return name ?? ""
    }

    static func classify(_ taps: [TapSnapshot], ownProcessID: pid_t) -> RivalTapState {
        let keyboard = (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue))
        for tap in taps {
            guard tap.enabled, tap.isActiveFilter, tap.processID != ownProcessID,
                  tap.targetProcessID == 0,
                  tap.location == .cghidEventTap || tap.location == .cgSessionEventTap,
                  tap.eventMask & keyboard != 0,
                  let path = tap.executablePath, !path.isEmpty,
                  !systemPrefixes.contains(where: { path.hasPrefix($0) }) else { continue }
            let name = tap.displayName ?? URL(fileURLWithPath: path).lastPathComponent
            return .active(programName: name.isEmpty ? nil : name)
        }
        return .none
    }

    static func liveState() -> RivalTapState {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return .none }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return .none }
        let snapshots = list.prefix(Int(count)).map { info in
            TapSnapshot(processID: info.tappingProcess, enabled: info.enabled,
                isActiveFilter: info.options == .defaultTap, targetProcessID: info.processBeingTapped,
                location: info.tapPoint, eventMask: info.eventsOfInterest,
                executablePath: path(of: info.tappingProcess),
                displayName: NSRunningApplication(processIdentifier: info.tappingProcess)?.localizedName)
        }
        return classify(Array(snapshots), ownProcessID: ProcessInfo.processInfo.processIdentifier)
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
