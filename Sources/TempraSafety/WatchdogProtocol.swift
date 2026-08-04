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
    public static let automaticResumeArmed: UInt8 = 0x41
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

public struct WatchdogCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case update
        case armResume
        case synchronizeResume
        case disarm
    }

    public let action: Action
    public let processes: [WatchdogProcessIdentity]
    public let resumeDeadlines: [WatchdogResumeDeadline]

    public init(
        action: Action,
        processes: [WatchdogProcessIdentity],
        resumeDeadlines: [WatchdogResumeDeadline] = []
    ) {
        self.action = action
        self.processes = processes
        self.resumeDeadlines = resumeDeadlines
    }
}

public enum WatchdogProtocolError: Error, Equatable {
    case frameTooLarge
    case incompleteFrame
    case invalidCommand
    case tooManyProcesses
}

public struct WatchdogCommandStream: Sendable {
    public static let maximumFrameBytes = 512 * 1_024
    public static let maximumProcessCount = 4_096

    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [WatchdogCommand] {
        guard data.count <= Self.maximumFrameBytes,
              buffer.count <= Self.maximumFrameBytes - data.count else {
            throw WatchdogProtocolError.frameTooLarge
        }
        buffer.append(data)

        var commands: [WatchdogCommand] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            guard !frame.isEmpty else { continue }
            guard frame.count <= Self.maximumFrameBytes else {
                throw WatchdogProtocolError.frameTooLarge
            }
            let command: WatchdogCommand
            do {
                command = try JSONDecoder().decode(WatchdogCommand.self, from: frame)
            } catch {
                throw WatchdogProtocolError.invalidCommand
            }
            guard command.processes.count <= Self.maximumProcessCount,
                  command.resumeDeadlines.count <= Self.maximumProcessCount else {
                throw WatchdogProtocolError.tooManyProcesses
            }
            guard Self.isValid(command) else {
                throw WatchdogProtocolError.invalidCommand
            }
            commands.append(command)
        }
        return commands
    }

    public func finish() throws {
        guard buffer.isEmpty else {
            throw WatchdogProtocolError.incompleteFrame
        }
    }

    private static func isValid(_ command: WatchdogCommand) -> Bool {
        let deadlineProcesses = command.resumeDeadlines.map(\.process)
        let deadlinesAreUnique = Set(deadlineProcesses).count == deadlineProcesses.count
        let deadlinesAreBounded = command.resumeDeadlines.allSatisfy {
            $0.resumeAfterMilliseconds > 0
                && $0.resumeAfterMilliseconds <= UInt32(Int32.max)
        }
        switch command.action {
        case .update:
            return command.resumeDeadlines.isEmpty
        case .armResume:
            return command.processes.isEmpty
                && !command.resumeDeadlines.isEmpty
                && deadlinesAreUnique
                && deadlinesAreBounded
        case .synchronizeResume:
            return command.processes.isEmpty
                && deadlinesAreUnique
                && deadlinesAreBounded
        case .disarm:
            return command.processes.isEmpty && command.resumeDeadlines.isEmpty
        }
    }
}
