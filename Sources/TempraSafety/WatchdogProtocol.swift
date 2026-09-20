import Foundation

public struct WatchdogProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startTimeMicroseconds: UInt64

    public init(pid: Int32, startTimeMicroseconds: UInt64) {
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

public enum WatchdogAcknowledgement {
    public static let privilegedStateSynchronized: UInt8 = 0x50
}

public struct WatchdogResumeDeadline: Codable, Equatable, Sendable {
    public let process: WatchdogProcessIdentity
    public let resumeAfterMilliseconds: UInt32

    public init(
        process: WatchdogProcessIdentity,
        resumeAfterMilliseconds: UInt32
    ) {
        self.process = process
        self.resumeAfterMilliseconds = resumeAfterMilliseconds
    }
}

public struct WatchdogProcessPriorityState: Codable, Equatable, Sendable {
    public let process: WatchdogProcessIdentity
    public let originalPriority: ProcessPriorityPolicyState

    public init(
        process: WatchdogProcessIdentity,
        originalPriority: ProcessPriorityPolicyState
    ) {
        self.process = process
        self.originalPriority = originalPriority
    }
}
