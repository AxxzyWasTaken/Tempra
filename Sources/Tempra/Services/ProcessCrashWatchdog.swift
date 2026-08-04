import Darwin
import Foundation
import OSLog
import TempraSafety

protocol ProcessCrashWatchdogControlling: Sendable {
    func prepareToStop(_ processes: Set<ProcessIdentity>) async throws
    func armAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws
    func synchronizeAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws
    func synchronize(_ processes: Set<ProcessIdentity>) async throws
    func disarm() async
}

enum ProcessCrashWatchdogError: LocalizedError {
    case helperUnavailable
    case helperLaunchFailed(String)
    case helperCommunicationFailed(String)
    case invalidResumeDeadline
    case tooManyProcesses

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "Tempra’s process safety helper is unavailable."
        case .helperLaunchFailed(let detail):
            "Tempra could not start its process safety helper: \(detail)"
        case .helperCommunicationFailed(let detail):
            "Tempra lost contact with its process safety helper: \(detail)"
        case .invalidResumeDeadline:
            "Tempra could not set a safe automatic resume deadline."
        case .tooManyProcesses:
            "Tempra cannot safely track this many paused processes."
        }
    }
}

actor ProcessCrashWatchdog: ProcessCrashWatchdogControlling {
    typealias HelperURLProvider = @Sendable () -> URL?

    private static let automaticResumeAcknowledgementTimeout: Duration = .seconds(1)
    private let helperURLProvider: HelperURLProvider
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.temperapp.Temper",
        category: "ProcessSafety"
    )
    private var helperProcess: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var pendingAutomaticResumeAcknowledgement:
        CheckedContinuation<Void, any Error>?
    private var automaticResumeAcknowledgementTimeoutTask: Task<Void, Never>?
    private var trackedProcesses: Set<ProcessIdentity> = []
    private var automaticResumeMillisecondsByProcess: [ProcessIdentity: UInt32] = [:]

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

    func armAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws {
        let processes = Set(intervalsByProcess.keys)
        guard !processes.isEmpty, processes.isSubset(of: trackedProcesses) else {
            throw ProcessCrashWatchdogError.invalidResumeDeadline
        }
        guard processes.count <= WatchdogCommandStream.maximumProcessCount else {
            throw ProcessCrashWatchdogError.tooManyProcesses
        }
        let millisecondsByProcess = try Self.resumeMilliseconds(
            for: intervalsByProcess
        )
        try ensureHelperIsRunning()
        try await writeAndAwaitAutomaticResumeAcknowledgement(WatchdogCommand(
            action: .armResume,
            processes: [],
            resumeDeadlines: Self.resumeDeadlines(for: millisecondsByProcess)
        ))
        automaticResumeMillisecondsByProcess.merge(
            millisecondsByProcess,
            uniquingKeysWith: { _, newValue in newValue }
        )
    }

    func synchronizeAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) throws {
        let processes = Set(intervalsByProcess.keys)
        guard processes.isSubset(of: trackedProcesses) else {
            throw ProcessCrashWatchdogError.invalidResumeDeadline
        }
        guard processes.count <= WatchdogCommandStream.maximumProcessCount else {
            throw ProcessCrashWatchdogError.tooManyProcesses
        }
        let millisecondsByProcess = try Self.resumeMilliseconds(
            for: intervalsByProcess
        )
        if processes.isEmpty, helperProcess?.isRunning != true {
            automaticResumeMillisecondsByProcess.removeAll()
            return
        }

        try ensureHelperIsRunning()
        try write(WatchdogCommand(
            action: .synchronizeResume,
            processes: [],
            resumeDeadlines: Self.resumeDeadlines(for: millisecondsByProcess)
        ))
        automaticResumeMillisecondsByProcess = millisecondsByProcess
    }

    func synchronize(_ processes: Set<ProcessIdentity>) throws {
        if processes.isEmpty {
            guard helperProcess?.isRunning == true else {
                trackedProcesses.removeAll()
                automaticResumeMillisecondsByProcess.removeAll()
                closeConnection()
                return
            }
        }
        try sendUpdate(processes)
    }

    func disarm() {
        guard helperProcess != nil else {
            trackedProcesses.removeAll()
            automaticResumeMillisecondsByProcess.removeAll()
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
        automaticResumeMillisecondsByProcess.removeAll()
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
        automaticResumeMillisecondsByProcess = automaticResumeMillisecondsByProcess.filter {
            processes.contains($0.key)
        }
    }

    private func ensureHelperIsRunning() throws {
        if let helperProcess,
           helperProcess.isRunning,
           inputHandle != nil,
           outputHandle != nil {
            return
        }
        closeConnection()

        guard let helperURL = helperURLProvider(),
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ProcessCrashWatchdogError.helperUnavailable
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = helperURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProcessCrashWatchdogError.helperLaunchFailed(error.localizedDescription)
        }

        let inputHandle = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        guard fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let failure = String(cString: strerror(errno))
            inputHandle.closeFile()
            outputHandle.closeFile()
            throw ProcessCrashWatchdogError.helperCommunicationFailed(failure)
        }
        helperProcess = process
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
        outputHandle.readabilityHandler = { [weak self] readableHandle in
            var acknowledgement: UInt8 = 0
            let readCount = withUnsafeMutableBytes(of: &acknowledgement) { buffer in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.read(
                    readableHandle.fileDescriptor,
                    baseAddress,
                    buffer.count
                )
            }
            let data = readCount == 1 ? Data([acknowledgement]) : Data()
            Task {
                await self?.receiveAutomaticResumeAcknowledgement(data)
            }
        }
        if !trackedProcesses.isEmpty {
            do {
                try write(Self.updateCommand(for: trackedProcesses))
                if !automaticResumeMillisecondsByProcess.isEmpty {
                    try write(WatchdogCommand(
                        action: .synchronizeResume,
                        processes: [],
                        resumeDeadlines: Self.resumeDeadlines(
                            for: automaticResumeMillisecondsByProcess
                        )
                    ))
                }
            } catch {
                closeConnection()
                throw error
            }
        }
    }

    private func writeAndAwaitAutomaticResumeAcknowledgement(
        _ command: WatchdogCommand
    ) async throws {
        guard pendingAutomaticResumeAcknowledgement == nil else {
            throw ProcessCrashWatchdogError.helperCommunicationFailed(
                "an automatic-resume acknowledgement is already pending"
            )
        }

        try await withCheckedThrowingContinuation { continuation in
            pendingAutomaticResumeAcknowledgement = continuation
            automaticResumeAcknowledgementTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: Self.automaticResumeAcknowledgementTimeout)
                } catch {
                    return
                }
                await self?.automaticResumeAcknowledgementTimedOut()
            }
            do {
                try write(command)
            } catch {
                failPendingAutomaticResumeAcknowledgement(with: error)
            }
        }
    }

    private func receiveAutomaticResumeAcknowledgement(_ data: Data) {
        guard data == Data([WatchdogAcknowledgement.automaticResumeArmed]) else {
            failPendingAutomaticResumeAcknowledgement(
                with: ProcessCrashWatchdogError.helperCommunicationFailed(
                    data.isEmpty
                        ? "the process safety helper closed its acknowledgement channel"
                        : "the process safety helper sent an invalid acknowledgement"
                )
            )
            closeConnection()
            return
        }
        guard let continuation = pendingAutomaticResumeAcknowledgement else {
            closeConnection()
            return
        }
        pendingAutomaticResumeAcknowledgement = nil
        automaticResumeAcknowledgementTimeoutTask?.cancel()
        automaticResumeAcknowledgementTimeoutTask = nil
        continuation.resume()
    }

    private func automaticResumeAcknowledgementTimedOut() {
        guard pendingAutomaticResumeAcknowledgement != nil else { return }
        failPendingAutomaticResumeAcknowledgement(
            with: ProcessCrashWatchdogError.helperCommunicationFailed(
                "the process safety helper did not confirm the automatic resume deadline"
            )
        )
        closeConnection()
    }

    private func failPendingAutomaticResumeAcknowledgement(with error: any Error) {
        guard let continuation = pendingAutomaticResumeAcknowledgement else { return }
        pendingAutomaticResumeAcknowledgement = nil
        automaticResumeAcknowledgementTimeoutTask?.cancel()
        automaticResumeAcknowledgementTimeoutTask = nil
        continuation.resume(throwing: error)
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
        failPendingAutomaticResumeAcknowledgement(
            with: ProcessCrashWatchdogError.helperCommunicationFailed(
                "the process safety helper connection closed"
            )
        )
        outputHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        outputHandle?.closeFile()
        inputHandle = nil
        outputHandle = nil
        helperProcess = nil
    }

    private static func updateCommand(
        for processes: Set<ProcessIdentity>
    ) -> WatchdogCommand {
        WatchdogCommand(action: .update, processes: identities(for: processes))
    }

    private static func resumeMilliseconds(
        for intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) throws -> [ProcessIdentity: UInt32] {
        guard intervalsByProcess.count <= WatchdogCommandStream.maximumProcessCount else {
            throw ProcessCrashWatchdogError.tooManyProcesses
        }
        var result: [ProcessIdentity: UInt32] = [:]
        result.reserveCapacity(intervalsByProcess.count)
        for (process, interval) in intervalsByProcess {
            guard interval.isFinite, interval > 0 else {
                throw ProcessCrashWatchdogError.invalidResumeDeadline
            }
            let milliseconds = ceil(interval * 1_000)
            guard milliseconds <= Double(Int32.max) else {
                throw ProcessCrashWatchdogError.invalidResumeDeadline
            }
            result[process] = UInt32(milliseconds)
        }
        return result
    }

    private static func resumeDeadlines(
        for millisecondsByProcess: [ProcessIdentity: UInt32]
    ) -> [WatchdogResumeDeadline] {
        millisecondsByProcess.map { process, milliseconds in
            WatchdogResumeDeadline(
                process: WatchdogProcessIdentity(
                    pid: Int32(process.pid),
                    startTimeMicroseconds: process.startTimeMicroseconds
                ),
                resumeAfterMilliseconds: milliseconds
            )
        }.sorted {
            if $0.process.pid != $1.process.pid {
                return $0.process.pid < $1.process.pid
            }
            return $0.process.startTimeMicroseconds
                < $1.process.startTimeMicroseconds
        }
    }

    private static func identities(
        for processes: Set<ProcessIdentity>
    ) -> [WatchdogProcessIdentity] {
        processes.map {
            WatchdogProcessIdentity(
                pid: Int32($0.pid),
                startTimeMicroseconds: $0.startTimeMicroseconds
            )
        }.sorted {
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.startTimeMicroseconds < $1.startTimeMicroseconds
        }
    }
}
