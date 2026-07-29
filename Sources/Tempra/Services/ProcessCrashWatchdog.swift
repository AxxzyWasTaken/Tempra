import Darwin
import Foundation
import OSLog
import TempraSafety

protocol ProcessCrashWatchdogControlling: Sendable {
    func prepareToStop(_ processes: Set<ProcessIdentity>) async throws
    func synchronize(_ processes: Set<ProcessIdentity>) async throws
    func disarm() async
}

enum ProcessCrashWatchdogError: LocalizedError {
    case helperUnavailable
    case helperLaunchFailed(String)
    case helperCommunicationFailed(String)
    case tooManyProcesses

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "Tempra’s process safety helper is unavailable."
        case .helperLaunchFailed(let detail):
            "Tempra could not start its process safety helper: \(detail)"
        case .helperCommunicationFailed(let detail):
            "Tempra lost contact with its process safety helper: \(detail)"
        case .tooManyProcesses:
            "Tempra cannot safely track this many paused processes."
        }
    }
}

actor ProcessCrashWatchdog: ProcessCrashWatchdogControlling {
    typealias HelperURLProvider = @Sendable () -> URL?

    private let helperURLProvider: HelperURLProvider
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.temperapp.Temper",
        category: "ProcessSafety"
    )
    private var helperProcess: Process?
    private var inputHandle: FileHandle?
    private var trackedProcesses: Set<ProcessIdentity> = []

    init(helperURLProvider: @escaping HelperURLProvider = {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        return executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("TempraWatchdog", isDirectory: false)
    }) {
        self.helperURLProvider = helperURLProvider
    }

    func prepareToStop(_ processes: Set<ProcessIdentity>) throws {
        try sendUpdate(trackedProcesses.union(processes))
    }

    func synchronize(_ processes: Set<ProcessIdentity>) throws {
        if processes.isEmpty {
            guard helperProcess?.isRunning == true else {
                trackedProcesses.removeAll()
                closeConnection()
                return
            }
        }
        try sendUpdate(processes)
    }

    func disarm() {
        guard helperProcess != nil else {
            trackedProcesses.removeAll()
            return
        }

        do {
            try write(WatchdogCommand(action: .disarm, processes: []))
        } catch {
            // Closing the pipe is the helper's crash-recovery signal. At this point the
            // controller has already resumed every tracked process.
            logger.error("Could not disarm process safety helper cleanly: \(error.localizedDescription)")
        }
        trackedProcesses.removeAll()
        closeConnection()
    }

    private func sendUpdate(_ processes: Set<ProcessIdentity>) throws {
        guard processes.count <= WatchdogCommandStream.maximumProcessCount else {
            throw ProcessCrashWatchdogError.tooManyProcesses
        }
        let processesAreUnchanged = processes == trackedProcesses
        try ensureHelperIsRunning()
        guard !processesAreUnchanged else { return }
        try write(Self.updateCommand(for: processes))
        trackedProcesses = processes
    }

    private func ensureHelperIsRunning() throws {
        if let helperProcess, helperProcess.isRunning, inputHandle != nil {
            return
        }
        closeConnection()

        guard let helperURL = helperURLProvider(),
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ProcessCrashWatchdogError.helperUnavailable
        }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = helperURL
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProcessCrashWatchdogError.helperLaunchFailed(error.localizedDescription)
        }

        let inputHandle = pipe.fileHandleForWriting
        guard fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let failure = String(cString: strerror(errno))
            inputHandle.closeFile()
            throw ProcessCrashWatchdogError.helperCommunicationFailed(failure)
        }
        helperProcess = process
        self.inputHandle = inputHandle
        if !trackedProcesses.isEmpty {
            do {
                try write(Self.updateCommand(for: trackedProcesses))
            } catch {
                closeConnection()
                throw error
            }
        }
    }

    private func write(_ command: WatchdogCommand) throws {
        guard let helperProcess, helperProcess.isRunning, let inputHandle else {
            throw ProcessCrashWatchdogError.helperCommunicationFailed(
                "the helper process is not running"
            )
        }

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(command)
        } catch {
            throw ProcessCrashWatchdogError.helperCommunicationFailed(
                error.localizedDescription
            )
        }
        guard encoded.count < WatchdogCommandStream.maximumFrameBytes else {
            throw ProcessCrashWatchdogError.tooManyProcesses
        }

        var frame = encoded
        frame.append(0x0A)
        do {
            try inputHandle.write(contentsOf: frame)
        } catch {
            closeConnection()
            throw ProcessCrashWatchdogError.helperCommunicationFailed(
                error.localizedDescription
            )
        }
    }

    private func closeConnection() {
        inputHandle?.closeFile()
        inputHandle = nil
        helperProcess = nil
    }

    private static func updateCommand(
        for processes: Set<ProcessIdentity>
    ) -> WatchdogCommand {
        let identities = processes.map {
            WatchdogProcessIdentity(
                pid: Int32($0.pid),
                startTimeMicroseconds: $0.startTimeMicroseconds
            )
        }.sorted {
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.startTimeMicroseconds < $1.startTimeMicroseconds
        }
        return WatchdogCommand(action: .update, processes: identities)
    }
}
