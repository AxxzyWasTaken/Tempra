import Darwin
import Foundation
import Security

public enum PrivilegedProcessProtocol {
    public static let version = 4
    public static let daemonPlistName = "io.github.temperapp.Temper.PrivilegedHelper.plist"
    public static let machServiceName = "io.github.temperapp.Temper.PrivilegedHelper"
    public static let applicationIdentifier = "io.github.temperapp.Temper"
    public static let helperIdentifier = "io.github.temperapp.Temper.PrivilegedHelper"
    public static let forceQuitSignal = SIGKILL
    public static let maximumFrameBytes = 512 * 1_024
    public static let maximumProcessCount = 4_096
}

@objc public protocol PrivilegedProcessXPCProtocol {
    func send(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum PrivilegedProcessAction: String, Codable, Sendable {
    case ping
    case snapshot
    case totalCPUTime
    case stop
    case resume
    case lowerPriority
    case limitPriority
    case restorePriority
    case acknowledgeResumeRecovery
    case acknowledgePriorityRecovery
    case terminate
}

public struct PrivilegedProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startTimeMicroseconds: UInt64

    public init(pid: Int32, startTimeMicroseconds: UInt64) {
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

public struct PrivilegedProcessRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let action: PrivilegedProcessAction
    public let processIdentifiers: [Int32]
    public let processes: [PrivilegedProcessIdentity]
    public let automaticResumeAfterMilliseconds: UInt32?

    public init(
        protocolVersion: Int = PrivilegedProcessProtocol.version,
        action: PrivilegedProcessAction,
        processIdentifiers: [Int32] = [],
        processes: [PrivilegedProcessIdentity] = [],
        automaticResumeAfterMilliseconds: UInt32? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.action = action
        self.processIdentifiers = processIdentifiers
        self.processes = processes
        self.automaticResumeAfterMilliseconds = automaticResumeAfterMilliseconds
    }
}

public struct PrivilegedProcessSnapshot: Codable, Equatable, Sendable {
    public let identity: PrivilegedProcessIdentity
    public let parentPID: Int32
    public let userID: UInt32
    public let executableName: String
    public let executablePath: String
    public let totalCPUTimeNanoseconds: UInt64
    public let residentMemoryBytes: UInt64

    public init(
        identity: PrivilegedProcessIdentity,
        parentPID: Int32,
        userID: UInt32,
        executableName: String,
        executablePath: String,
        totalCPUTimeNanoseconds: UInt64,
        residentMemoryBytes: UInt64
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.userID = userID
        self.executableName = executableName
        self.executablePath = executablePath
        self.totalCPUTimeNanoseconds = totalCPUTimeNanoseconds
        self.residentMemoryBytes = residentMemoryBytes
    }
}

public enum PrivilegedProcessErrorCode: String, Codable, Sendable {
    case invalidRequest
    case requestTooLarge
    case tooManyProcesses
    case operationFailed
    case safetyHelperFailed
}

public struct PrivilegedProcessResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let snapshots: [PrivilegedProcessSnapshot]
    public let applied: [PrivilegedProcessIdentity]
    public let stale: [PrivilegedProcessIdentity]
    public let failed: [PrivilegedProcessIdentity]
    public let totalCPUTimeNanoseconds: UInt64
    public let errorCode: PrivilegedProcessErrorCode?
    public let errorMessage: String?

    public init(
        protocolVersion: Int = PrivilegedProcessProtocol.version,
        snapshots: [PrivilegedProcessSnapshot] = [],
        applied: [PrivilegedProcessIdentity] = [],
        stale: [PrivilegedProcessIdentity] = [],
        failed: [PrivilegedProcessIdentity] = [],
        totalCPUTimeNanoseconds: UInt64 = 0,
        errorCode: PrivilegedProcessErrorCode? = nil,
        errorMessage: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.snapshots = snapshots
        self.applied = applied
        self.stale = stale
        self.failed = failed
        self.totalCPUTimeNanoseconds = totalCPUTimeNanoseconds
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public enum CodeSigningRequirementError: LocalizedError, Sendable {
    case signingInformationUnavailable
    case staticCodeUnavailable
    case codeIdentifierUnavailable
    case teamIdentifierUnavailable
    case invalidIdentifier

    public var errorDescription: String? {
        switch self {
        case .signingInformationUnavailable:
            "The code-signing information is unavailable."
        case .staticCodeUnavailable:
            "The bundled helper code signature is unavailable."
        case .codeIdentifierUnavailable:
            "The bundled helper code identifier is unavailable."
        case .teamIdentifierUnavailable:
            "The app does not have a code-signing team identifier."
        case .invalidIdentifier:
            "The code-signing identifier is invalid."
        }
    }
}

public enum TempraCodeSigningRequirement {
    public static func staticCodeIdentifier(at executableURL: URL) throws -> Data {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            throw CodeSigningRequirementError.staticCodeUnavailable
        }

        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess,
              let information = rawInformation as? [CFString: Any],
              let identifier = information[kSecCodeInfoUnique] as? Data,
              !identifier.isEmpty else {
            throw CodeSigningRequirementError.codeIdentifierUnavailable
        }
        return identifier
    }

    public static func peerRequirement(identifier: String) throws -> String {
        let allowedIdentifierCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
        )
        guard !identifier.isEmpty,
              identifier.unicodeScalars.allSatisfy(allowedIdentifierCharacters.contains) else {
            throw CodeSigningRequirementError.invalidIdentifier
        }

        var runningCode: SecCode?
        guard SecCodeCopySelf([], &runningCode) == errSecSuccess,
              let runningCode else {
            throw CodeSigningRequirementError.signingInformationUnavailable
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            runningCode,
            [],
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            throw CodeSigningRequirementError.signingInformationUnavailable
        }

        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess,
        let information = rawInformation as? [CFString: Any],
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
        !teamIdentifier.isEmpty,
        teamIdentifier.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0)
        }) else {
            throw CodeSigningRequirementError.teamIdentifierUnavailable
        }

        return "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
