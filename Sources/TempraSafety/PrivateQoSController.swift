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

public struct ProcessPriorityPolicyState: Codable, Equatable, Hashable, Sendable {
    public let isBackgrounded: Bool

    public init(isBackgrounded: Bool) {
        self.isBackgrounded = isBackgrounded
    }

    public static let normal = ProcessPriorityPolicyState(isBackgrounded: false)
    public static let backgrounded = ProcessPriorityPolicyState(isBackgrounded: true)
}

public enum ProcessPriorityControllerError: LocalizedError, Equatable, Sendable {
    case invalidProcessIdentifier
    case priorityReadFailed(Int32)
    case priorityWriteFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidProcessIdentifier:
            "The priority request contains an invalid process identifier."
        case .priorityReadFailed(let code):
            "Tempra could not read the process priority (POSIX error \(code))."
        case .priorityWriteFailed(let code):
            "Tempra could not change the process priority (POSIX error \(code))."
        }
    }

    /// True when the kernel refused the write for lack of privilege, so a
    /// privileged caller may still succeed.
    public var isPermissionDenied: Bool {
        switch self {
        case .priorityWriteFailed(let code), .priorityReadFailed(let code):
            code == EPERM
        case .invalidProcessIdentifier:
            false
        }
    }
}

public struct ProcessPriorityController: Sendable {
    public init() {}

    /// The state a lowered process should be in. Independent of the
    /// original state: backgrounding is idempotent.
    public static func loweredState(
        from original: ProcessPriorityPolicyState
    ) -> ProcessPriorityPolicyState {
        .backgrounded
    }

    /// The state a process should be in while the CPU limiter is pulsing it.
    /// Backgrounding is the only Darwin priority knob that measurably slows a
    /// process, so the limiter pulse uses the same state as lowering.
    public static func limitState(
        from original: ProcessPriorityPolicyState
    ) -> ProcessPriorityPolicyState {
        .backgrounded
    }

    static func shouldRestore(
        current: ProcessPriorityPolicyState,
        original: ProcessPriorityPolicyState
    ) -> Bool {
        current != original
    }

    public func state(for processIdentifier: Int32) throws -> ProcessPriorityPolicyState {
        guard processIdentifier > 1 else {
            throw ProcessPriorityControllerError.invalidProcessIdentifier
        }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let readSize = proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard readSize == expectedSize else {
            throw ProcessPriorityControllerError.priorityReadFailed(errno == 0 ? ESRCH : errno)
        }
        return ProcessPriorityPolicyState(
            isBackgrounded: info.pbi_flags & DarwinBackgroundPriority.backgroundedFlags != 0
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

    public func restore(
        _ state: ProcessPriorityPolicyState,
        to processIdentifier: Int32
    ) throws {
        let current = try self.state(for: processIdentifier)
        guard Self.shouldRestore(current: current, original: state) else { return }
        try write(state, to: processIdentifier)
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
}
