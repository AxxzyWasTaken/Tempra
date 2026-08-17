import Foundation

public enum ProcessGuardianProtocol {
    public static let version = 1
    public static let agentPlistName = "io.github.temperapp.Temper.ProcessGuardian.plist"
    public static let machServiceName = "io.github.temperapp.Temper.ProcessGuardian"
    public static let applicationIdentifier = "io.github.temperapp.Temper"
    public static let guardianIdentifier = "io.github.temperapp.Temper.watchdog"
    public static let journalSchemaVersion = 1
    public static let journalFileName = "process-guardian-state.json"
    public static let maximumFrameBytes = 512 * 1_024
    public static let maximumProcessCount = 4_096
    public static let heartbeatIntervalMilliseconds: UInt64 = 1_000
    public static let leaseDurationMilliseconds: UInt64 = 5_000
}

@objc public protocol ProcessGuardianXPCProtocol {
    func send(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    )
}

public enum ProcessGuardianAction: String, Codable, Sendable {
    case ping
    case prepare
    case synchronize
    case armResume
    case synchronizeResume
    case stop
    case resume
    case renewLease
    case disarm
}

public struct ProcessGuardianRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let sessionID: UUID
    public let requestID: UUID
    public let revision: UInt64
    public let action: ProcessGuardianAction
    public let owner: WatchdogProcessIdentity
    public let processes: [WatchdogProcessIdentity]
    public let resumeDeadlines: [WatchdogResumeDeadline]

    public init(
        protocolVersion: Int = ProcessGuardianProtocol.version,
        sessionID: UUID,
        requestID: UUID = UUID(),
        revision: UInt64,
        action: ProcessGuardianAction,
        owner: WatchdogProcessIdentity,
        processes: [WatchdogProcessIdentity] = [],
        resumeDeadlines: [WatchdogResumeDeadline] = []
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.requestID = requestID
        self.revision = revision
        self.action = action
        self.owner = owner
        self.processes = processes
        self.resumeDeadlines = resumeDeadlines
    }

    public var isValid: Bool {
        guard protocolVersion == ProcessGuardianProtocol.version,
              revision > 0,
              owner.pid > 1,
              owner.startTimeMicroseconds > 0,
              processes.count <= ProcessGuardianProtocol.maximumProcessCount,
              resumeDeadlines.count <= ProcessGuardianProtocol.maximumProcessCount,
              Set(processes).count == processes.count,
              Set(processes.map(\.pid)).count == processes.count,
              processes.allSatisfy({
                  $0.pid > 1 && $0.startTimeMicroseconds > 0
              }) else {
            return false
        }

        let deadlineProcesses = resumeDeadlines.map(\.process)
        let deadlinesAreValid = Set(deadlineProcesses).count == deadlineProcesses.count
            && Set(deadlineProcesses.map(\.pid)).count == deadlineProcesses.count
            && resumeDeadlines.allSatisfy {
                $0.process.pid > 1
                    && $0.process.startTimeMicroseconds > 0
                    && $0.resumeAfterMilliseconds > 0
                    && $0.resumeAfterMilliseconds <= UInt32(Int32.max)
            }
        guard deadlinesAreValid else { return false }

        switch action {
        case .ping, .renewLease, .disarm:
            return processes.isEmpty && resumeDeadlines.isEmpty
        case .prepare, .synchronize, .resume:
            return resumeDeadlines.isEmpty
        case .armResume, .synchronizeResume:
            return processes.isEmpty
        case .stop:
            return Set(deadlineProcesses).isSubset(of: Set(processes))
        }
    }
}

public enum ProcessGuardianErrorCode: String, Codable, Sendable {
    case invalidRequest
    case staleRevision
    case sessionMismatch
    case journalFailure
    case operationFailed
    case recoveryFailed
    case leaseExpired
}

public struct ProcessGuardianResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let sessionID: UUID
    public let requestID: UUID
    public let revision: UInt64
    public let guardianInstanceID: UUID
    public let applied: [WatchdogProcessIdentity]
    public let stale: [WatchdogProcessIdentity]
    public let failed: [WatchdogProcessIdentity]
    public let errorCode: ProcessGuardianErrorCode?
    public let errorMessage: String?

    public init(
        protocolVersion: Int = ProcessGuardianProtocol.version,
        sessionID: UUID,
        requestID: UUID,
        revision: UInt64,
        guardianInstanceID: UUID,
        applied: [WatchdogProcessIdentity] = [],
        stale: [WatchdogProcessIdentity] = [],
        failed: [WatchdogProcessIdentity] = [],
        errorCode: ProcessGuardianErrorCode? = nil,
        errorMessage: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.requestID = requestID
        self.revision = revision
        self.guardianInstanceID = guardianInstanceID
        self.applied = applied
        self.stale = stale
        self.failed = failed
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}
