import Darwin
import Foundation

/// The Darwin-specific `setpriority(2)` selectors and values Tempra uses.
///
/// Classic Unix `nice` is nearly ignored by the macOS scheduler on Apple
/// silicon: measured under full-core contention, nice 10 or 20 changed a
/// spinner's runtime by under 10%. `PRIO_DARWIN_BG` is the mechanism the
/// system itself uses for background work. It confines the process to
/// efficiency cores, lowers it to the lowest scheduling band, and throttles
/// disk and network I/O; the same spinner ran about 50 times slower.
///
/// Whether a process is currently backgrounded is read from the
/// `PROC_FLAG_DARWINBG`-family bits in `proc_bsdinfo.pbi_flags`, not from
/// `getpriority(PRIO_DARWIN_PROCESS, pid)`, which only ever describes the
/// calling thread and returns 0 for other processes.
///
/// A process spawned while its parent is externally backgrounded inherits
/// the background state, and clearing the parent does not clear the child.
/// Restoring a process therefore also clears every descendant that started
/// after Tempra backgrounded the ancestor.
private enum DarwinBackgroundPriority {
    static let selector = PRIO_DARWIN_PROCESS
    static let background = PRIO_DARWIN_BG
    static let normal: Int32 = 0

    /// `pbi_flags` bit set when another process backgrounded this one
    /// (`PROC_FLAG_EXT_DARWINBG` in the private headers).
    static let externallyBackgroundedFlag: UInt32 = 0x10000
    /// `pbi_flags` bit set when the process backgrounded itself
    /// (`PROC_FLAG_DARWINBG` in the private headers).
    static let selfBackgroundedFlag: UInt32 = 0x8000
    static let backgroundedFlags = externallyBackgroundedFlag | selfBackgroundedFlag
}

/// A process's background state as observed at one moment.
///
/// `observedAtMicroseconds` is wall-clock time in the same domain as
/// `proc_bsdinfo.pbi_start_tvsec`, so a restore can tell which descendants
/// were spawned after the observation and inherited Tempra's change.
public struct ProcessPriorityPolicyState: Codable, Equatable, Hashable, Sendable {
    public let isBackgrounded: Bool
    public let observedAtMicroseconds: UInt64

    public init(isBackgrounded: Bool, observedAtMicroseconds: UInt64 = 0) {
        self.isBackgrounded = isBackgrounded
        self.observedAtMicroseconds = observedAtMicroseconds
    }

    public static let normal = ProcessPriorityPolicyState(isBackgrounded: false)
    public static let backgrounded = ProcessPriorityPolicyState(isBackgrounded: true)

    func replacing(isBackgrounded: Bool) -> ProcessPriorityPolicyState {
        ProcessPriorityPolicyState(
            isBackgrounded: isBackgrounded,
            observedAtMicroseconds: observedAtMicroseconds
        )
    }
}

public enum ProcessPriorityControllerError: LocalizedError, Equatable, Sendable {
    case invalidProcessIdentifier
    case priorityReadFailed(Int32)
    case priorityWriteFailed(Int32)
    case inheritedPriorityRestoreFailed(descendant: Int32, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidProcessIdentifier:
            "The priority request contains an invalid process identifier."
        case .priorityReadFailed(let code):
            "Tempra could not read the process priority (POSIX error \(code))."
        case .priorityWriteFailed(let code):
            "Tempra could not change the process priority (POSIX error \(code))."
        case .inheritedPriorityRestoreFailed(let descendant, let code):
            "Tempra could not restore the priority of child process \(descendant) (POSIX error \(code))."
        }
    }

    /// True when the kernel refused the write for lack of privilege, so a
    /// privileged caller may still succeed.
    public var isPermissionDenied: Bool {
        switch self {
        case .priorityWriteFailed(let code), .priorityReadFailed(let code),
             .inheritedPriorityRestoreFailed(_, let code):
            code == EPERM
        case .invalidProcessIdentifier:
            false
        }
    }
}

public struct ProcessPriorityController: Sendable {
    public init() {}

    /// The state a lowered process should be in. Backgrounding is idempotent,
    /// so the target is the same for every original.
    public static func loweredState(
        from original: ProcessPriorityPolicyState
    ) -> ProcessPriorityPolicyState {
        original.replacing(isBackgrounded: true)
    }

    /// The state a process should be in while the CPU limiter is pulsing it.
    /// Backgrounding is the only Darwin priority knob that measurably slows a
    /// process, so the limiter pulse uses the same state as lowering.
    public static func limitState(
        from original: ProcessPriorityPolicyState
    ) -> ProcessPriorityPolicyState {
        original.replacing(isBackgrounded: true)
    }

    static func shouldRestore(
        current: ProcessPriorityPolicyState,
        original: ProcessPriorityPolicyState
    ) -> Bool {
        current.isBackgrounded != original.isBackgrounded
    }

    public func state(for processIdentifier: Int32) throws -> ProcessPriorityPolicyState {
        guard processIdentifier > 1 else {
            throw ProcessPriorityControllerError.invalidProcessIdentifier
        }
        let observedAt = Self.wallClockMicroseconds()
        guard let info = Self.bsdInfo(for: processIdentifier) else {
            throw ProcessPriorityControllerError.priorityReadFailed(errno == 0 ? ESRCH : errno)
        }
        return ProcessPriorityPolicyState(
            isBackgrounded: Self.isBackgrounded(info),
            observedAtMicroseconds: observedAt
        )
    }

    public func lowerPriority(
        from original: ProcessPriorityPolicyState,
        for processIdentifier: Int32
    ) throws {
        try write(Self.loweredState(from: original), to: processIdentifier)
    }

    public func applyLimitPriority(
        from original: ProcessPriorityPolicyState,
        for processIdentifier: Int32
    ) throws {
        try write(Self.limitState(from: original), to: processIdentifier)
    }

    /// Returns the process to `state`. When that means leaving the background
    /// state, every descendant that was spawned after `state` was observed and
    /// is externally backgrounded is cleared too, because it inherited the
    /// state Tempra set on its ancestor.
    public func restore(
        _ state: ProcessPriorityPolicyState,
        to processIdentifier: Int32
    ) throws {
        let current = try self.state(for: processIdentifier)
        if Self.shouldRestore(current: current, original: state) {
            try write(state, to: processIdentifier)
        }
        guard !state.isBackgrounded else { return }
        try clearInheritedBackground(
            descendantsOf: processIdentifier,
            startedAfter: state.observedAtMicroseconds
        )
    }

    private func clearInheritedBackground(
        descendantsOf processIdentifier: Int32,
        startedAfter cutoffMicroseconds: UInt64
    ) throws {
        var pending = [processIdentifier]
        var visited: Set<Int32> = [processIdentifier]
        while let parent = pending.popLast() {
            for child in Self.childProcessIdentifiers(of: parent) where visited.insert(child).inserted {
                pending.append(child)
                guard let info = Self.bsdInfo(for: child),
                      info.pbi_flags & DarwinBackgroundPriority.externallyBackgroundedFlag != 0,
                      Self.startTimeMicroseconds(info) >= cutoffMicroseconds else {
                    continue
                }
                errno = 0
                guard setpriority(
                    DarwinBackgroundPriority.selector,
                    id_t(child),
                    DarwinBackgroundPriority.normal
                ) == 0 else {
                    throw ProcessPriorityControllerError.inheritedPriorityRestoreFailed(
                        descendant: child,
                        code: errno
                    )
                }
            }
        }
    }

    private func write(
        _ state: ProcessPriorityPolicyState,
        to processIdentifier: Int32
    ) throws {
        guard processIdentifier > 1 else {
            throw ProcessPriorityControllerError.invalidProcessIdentifier
        }

        errno = 0
        let result = setpriority(
            DarwinBackgroundPriority.selector,
            id_t(processIdentifier),
            state.isBackgrounded
                ? DarwinBackgroundPriority.background
                : DarwinBackgroundPriority.normal
        )
        guard result == 0 else {
            throw ProcessPriorityControllerError.priorityWriteFailed(errno)
        }
    }

    private static func isBackgrounded(_ info: proc_bsdinfo) -> Bool {
        info.pbi_flags & DarwinBackgroundPriority.backgroundedFlags != 0
    }

    private static func bsdInfo(for pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        return readSize == expectedSize ? info : nil
    }

    private static func startTimeMicroseconds(_ info: proc_bsdinfo) -> UInt64 {
        let seconds = UInt64(info.pbi_start_tvsec).multipliedReportingOverflow(by: 1_000_000)
        guard !seconds.overflow else { return .max }
        let total = seconds.partialValue.addingReportingOverflow(UInt64(info.pbi_start_tvusec))
        return total.overflow ? .max : total.partialValue
    }

    private static func wallClockMicroseconds() -> UInt64 {
        var now = timeval()
        gettimeofday(&now, nil)
        let seconds = UInt64(max(0, now.tv_sec)).multipliedReportingOverflow(by: 1_000_000)
        guard !seconds.overflow else { return .max }
        let total = seconds.partialValue.addingReportingOverflow(UInt64(max(0, now.tv_usec)))
        return total.overflow ? .max : total.partialValue
    }

    private static func childProcessIdentifiers(of pid: Int32) -> [Int32] {
        // proc_listchildpids returns a pid count, not a byte count.
        let expectedCount = proc_listchildpids(pid, nil, 0)
        guard expectedCount > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(expectedCount) + 16)
        let filledCount = proc_listchildpids(
            pid,
            &buffer,
            Int32(buffer.count * MemoryLayout<pid_t>.size)
        )
        guard filledCount > 0 else { return [] }
        return buffer.prefix(Int(filledCount)).filter { $0 > 1 }
    }
}
