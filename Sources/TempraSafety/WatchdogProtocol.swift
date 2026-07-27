import Foundation

public struct WatchdogProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startTimeMicroseconds: UInt64

    public init(pid: Int32, startTimeMicroseconds: UInt64) {
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

public struct WatchdogCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case update
        case disarm
    }

    public let action: Action
    public let processes: [WatchdogProcessIdentity]

    public init(action: Action, processes: [WatchdogProcessIdentity]) {
        self.action = action
        self.processes = processes
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
            guard command.processes.count <= Self.maximumProcessCount else {
                throw WatchdogProtocolError.tooManyProcesses
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
}
