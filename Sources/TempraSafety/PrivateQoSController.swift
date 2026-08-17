import Darwin
import Foundation

private enum POSIXProcessPriority {
    static let selector = PRIO_PROCESS
    static let minimumNiceValue = Int32(PRIO_MIN)
    static let maximumNiceValue = Int32(PRIO_MAX)
    static let lowerPriorityNiceValue: Int32 = 10
    static let limitPulseNiceValue: Int32 = 3
}

public struct ProcessPriorityPolicyState: Codable, Equatable, Hashable, Sendable {
    public let niceValue: Int32

    public init(niceValue: Int32) {
        self.niceValue = niceValue
    }

    public var isValid: Bool {
        (POSIXProcessPriority.minimumNiceValue...POSIXProcessPriority.maximumNiceValue)
            .contains(niceValue)
    }
}

public enum ProcessPriorityControllerError: LocalizedError, Equatable, Sendable {
    case invalidProcessIdentifier
    case priorityReadFailed(Int32)
    case priorityWriteFailed(Int32)
    case invalidPolicyState

    public var errorDescription: String? {
        switch self {
        case .invalidProcessIdentifier:
            "The priority request contains an invalid process identifier."
        case .priorityReadFailed(let code):
            "Tempra could not read the process priority (POSIX error \(code))."
        case .priorityWriteFailed(let code):
            "Tempra could not change the process priority (POSIX error \(code))."
        case .invalidPolicyState:
            "The saved process priority is invalid."
        }
    }
}

public struct ProcessPriorityController: Sendable {
    public static let lowerPriorityNiceValue = POSIXProcessPriority.lowerPriorityNiceValue
    public static let limitPulseNiceValue = POSIXProcessPriority.limitPulseNiceValue

    public init() {}

    public static func loweredState(
        from original: ProcessPriorityPolicyState
    ) throws -> ProcessPriorityPolicyState {
        guard original.isValid else {
            throw ProcessPriorityControllerError.invalidPolicyState
        }
        return ProcessPriorityPolicyState(
            niceValue: max(original.niceValue, lowerPriorityNiceValue)
        )
    }

    public static func limitState(
        from original: ProcessPriorityPolicyState
    ) throws -> ProcessPriorityPolicyState {
        guard original.isValid else {
            throw ProcessPriorityControllerError.invalidPolicyState
        }
        return ProcessPriorityPolicyState(
            niceValue: max(original.niceValue, limitPulseNiceValue)
        )
    }

    static func shouldRestore(
        current: ProcessPriorityPolicyState,
        original: ProcessPriorityPolicyState
    ) throws -> Bool {
        guard current.isValid else {
            throw ProcessPriorityControllerError.invalidPolicyState
        }
        let lowered = try loweredState(from: original)
        let limited = try limitState(from: original)
        return current == lowered || current == limited
    }

    public func state(for processIdentifier: Int32) throws -> ProcessPriorityPolicyState {
        guard processIdentifier > 1 else {
            throw ProcessPriorityControllerError.invalidProcessIdentifier
        }

        errno = 0
        let niceValue = getpriority(
            POSIXProcessPriority.selector,
            id_t(processIdentifier)
        )
        let readError = errno
        guard readError == 0 else {
            throw ProcessPriorityControllerError.priorityReadFailed(readError)
        }
        let state = ProcessPriorityPolicyState(niceValue: niceValue)
        guard state.isValid else {
            throw ProcessPriorityControllerError.invalidPolicyState
        }
        return state
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

    public func setNiceValue(
        _ niceValue: Int32,
        for processIdentifier: Int32
    ) throws {
        try write(ProcessPriorityPolicyState(niceValue: niceValue), to: processIdentifier)
    }

    public func restore(
        _ state: ProcessPriorityPolicyState,
        to processIdentifier: Int32
    ) throws {
        guard state.isValid else {
            throw ProcessPriorityControllerError.invalidPolicyState
        }
        let current = try self.state(for: processIdentifier)
        guard try Self.shouldRestore(current: current, original: state) else { return }
        try write(state, to: processIdentifier)
    }

    private func write(
        _ state: ProcessPriorityPolicyState,
        to processIdentifier: Int32
    ) throws {
        guard processIdentifier > 1 else {
            throw ProcessPriorityControllerError.invalidProcessIdentifier
        }
        guard state.isValid else {
            throw ProcessPriorityControllerError.invalidPolicyState
        }

        errno = 0
        let result = setpriority(
            POSIXProcessPriority.selector,
            id_t(processIdentifier),
            state.niceValue
        )
        guard result == 0 else {
            throw ProcessPriorityControllerError.priorityWriteFailed(errno)
        }
    }
}
