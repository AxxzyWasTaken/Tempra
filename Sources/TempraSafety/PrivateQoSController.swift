import Darwin
import Foundation

// These values match XNU's private sys/resource_private.h interface.
private enum PrivateDarwinRole {
    static let prioritySelector: Int32 = 6
    static let energyEfficient: Int32 = 5
    static let validRange = Int32(0)...Int32(7)
}

public struct PrivateQoSPolicyState: Codable, Equatable, Hashable, Sendable {
    public let darwinRole: Int32

    public init(darwinRole: Int32) {
        self.darwinRole = darwinRole
    }

    public var isValid: Bool {
        PrivateDarwinRole.validRange.contains(darwinRole)
    }
}

public enum PrivateQoSControllerError: LocalizedError, Equatable, Sendable {
    case invalidProcessIdentifier
    case policyReadFailed(Int32)
    case policyWriteFailed(Int32)
    case invalidPolicyState

    public var errorDescription: String? {
        switch self {
        case .invalidProcessIdentifier:
            "The private QoS request contains an invalid process identifier."
        case .policyReadFailed(let code):
            "Tempra could not read the existing private QoS role (POSIX error \(code))."
        case .policyWriteFailed(let code):
            "Tempra could not change the private QoS role (POSIX error \(code))."
        case .invalidPolicyState:
            "The saved private QoS policy is invalid."
        }
    }
}

public struct PrivateQoSController: Sendable {
    public static let energyEfficientState = PrivateQoSPolicyState(
        darwinRole: PrivateDarwinRole.energyEfficient
    )

    public init() {}

    public func state(for processIdentifier: Int32) throws -> PrivateQoSPolicyState {
        guard processIdentifier > 1 else {
            throw PrivateQoSControllerError.invalidProcessIdentifier
        }

        errno = 0
        let role = getpriority(
            PrivateDarwinRole.prioritySelector,
            id_t(processIdentifier)
        )
        let readError = errno
        guard readError == 0 else {
            throw PrivateQoSControllerError.policyReadFailed(readError)
        }
        let state = PrivateQoSPolicyState(darwinRole: role)
        guard state.isValid else {
            throw PrivateQoSControllerError.invalidPolicyState
        }
        return state
    }

    public func applyEnergyEfficientPolicy(to processIdentifier: Int32) throws {
        try write(Self.energyEfficientState, to: processIdentifier)
    }

    public func restore(
        _ state: PrivateQoSPolicyState,
        to processIdentifier: Int32
    ) throws {
        guard state.isValid else {
            throw PrivateQoSControllerError.invalidPolicyState
        }
        let current = try self.state(for: processIdentifier)
        guard current == Self.energyEfficientState else { return }
        try write(state, to: processIdentifier)
    }

    private func write(
        _ state: PrivateQoSPolicyState,
        to processIdentifier: Int32
    ) throws {
        guard processIdentifier > 1 else {
            throw PrivateQoSControllerError.invalidProcessIdentifier
        }
        guard state.isValid else {
            throw PrivateQoSControllerError.invalidPolicyState
        }

        errno = 0
        let result = setpriority(
            PrivateDarwinRole.prioritySelector,
            id_t(processIdentifier),
            state.darwinRole
        )
        guard result == 0 else {
            throw PrivateQoSControllerError.policyWriteFailed(errno)
        }
    }
}
