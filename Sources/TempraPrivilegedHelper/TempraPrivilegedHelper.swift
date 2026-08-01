import Darwin
import Foundation
import OSLog
import TempraSafety

private enum PrivilegedHelperFailure: LocalizedError {
    case invalidRequest(String)
    case safetyHelper(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail), .safetyHelper(let detail):
            detail
        }
    }
}

private struct PrivilegedWatchdogState: Codable {
    let stopped: [WatchdogProcessIdentity]
    let backgrounded: [WatchdogProcessIdentity]
}

private struct PrivilegedWatchdogStream {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [PrivilegedWatchdogState] {
        guard data.count <= PrivilegedProcessProtocol.maximumFrameBytes,
              buffer.count <= PrivilegedProcessProtocol.maximumFrameBytes - data.count else {
            throw PrivilegedHelperFailure.invalidRequest("The safety frame is too large.")
        }
        buffer.append(data)

        var states: [PrivilegedWatchdogState] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            guard !frame.isEmpty else { continue }
            let state = try JSONDecoder().decode(PrivilegedWatchdogState.self, from: frame)
            guard state.stopped.count <= PrivilegedProcessProtocol.maximumProcessCount,
                  state.backgrounded.count <= PrivilegedProcessProtocol.maximumProcessCount else {
                throw PrivilegedHelperFailure.invalidRequest(
                    "The safety frame contains too many processes."
                )
            }
            states.append(state)
        }
        return states
    }

    func finish() throws {
        guard buffer.isEmpty else {
            throw PrivilegedHelperFailure.invalidRequest("The safety frame is incomplete.")
        }
    }
}

private final class PrivilegedSafetyWatchdog {
    private let executableURL: URL
    private var process: Process?
    private var inputHandle: FileHandle?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func synchronize(
        stopped: Set<PrivilegedProcessIdentity>,
        backgrounded: Set<PrivilegedProcessIdentity>
    ) throws {
        if stopped.isEmpty, backgrounded.isEmpty, process == nil {
            return
        }
        try ensureRunning()
        let state = PrivilegedWatchdogState(
            stopped: stopped.map(Self.watchdogIdentity).sorted(by: Self.identityOrder),
            backgrounded: backgrounded.map(Self.watchdogIdentity).sorted(by: Self.identityOrder)
        )
        let encoded = try JSONEncoder().encode(state)
        guard encoded.count < PrivilegedProcessProtocol.maximumFrameBytes else {
            throw PrivilegedHelperFailure.safetyHelper(
                "The privileged safety update is too large."
            )
        }
        var frame = encoded
        frame.append(0x0A)
        do {
            try inputHandle?.write(contentsOf: frame)
        } catch {
            close()
            throw PrivilegedHelperFailure.safetyHelper(error.localizedDescription)
        }
    }

    func disarm() {
        inputHandle?.closeFile()
        inputHandle = nil
        process = nil
    }

    func triggerRecovery() {
        inputHandle?.closeFile()
        inputHandle = nil
        process = nil
    }

    private func ensureRunning() throws {
        if let process, process.isRunning, inputHandle != nil { return }
        close()

        let pipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--watchdog"]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw PrivilegedHelperFailure.safetyHelper(
                "Tempra could not start the privileged safety process: "
                    + error.localizedDescription
            )
        }
        let handle = pipe.fileHandleForWriting
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let detail = String(cString: strerror(errno))
            handle.closeFile()
            throw PrivilegedHelperFailure.safetyHelper(
                "Tempra could not configure the privileged safety connection: \(detail)"
            )
        }
        self.process = process
        inputHandle = handle
    }

    private func close() {
        inputHandle?.closeFile()
        inputHandle = nil
        process = nil
    }

    private static func watchdogIdentity(
        _ identity: PrivilegedProcessIdentity
    ) -> WatchdogProcessIdentity {
        WatchdogProcessIdentity(
            pid: identity.pid,
            startTimeMicroseconds: identity.startTimeMicroseconds
        )
    }

    private static func identityOrder(
        _ first: WatchdogProcessIdentity,
        _ second: WatchdogProcessIdentity
    ) -> Bool {
        if first.pid != second.pid { return first.pid < second.pid }
        return first.startTimeMicroseconds < second.startTimeMicroseconds
    }
}

private final class PrivilegedProcessSession: NSObject, PrivilegedProcessXPCProtocol {
    private let queue = DispatchQueue(label: "io.github.temperapp.Temper.privileged-session")
    private let helperPID = getpid()
    private let helperExecutablePath: String
    private let watchdog: PrivilegedSafetyWatchdog
    private var stopped: Set<PrivilegedProcessIdentity> = []
    private var backgrounded: Set<PrivilegedProcessIdentity> = []
    private var isInvalidated = false

    init(executableURL: URL) {
        helperExecutablePath = executableURL.standardizedFileURL.path
        watchdog = PrivilegedSafetyWatchdog(executableURL: executableURL)
    }

    func send(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            guard let self, !isInvalidated else {
                reply(Self.encode(PrivilegedProcessResponse(
                    errorCode: .operationFailed,
                    errorMessage: "The privileged connection is closed."
                )))
                return
            }
            reply(Self.encode(handle(request)))
        }
    }

    func invalidate() {
        queue.async { [weak self] in
            guard let self, !isInvalidated else { return }
            isInvalidated = true
            watchdog.triggerRecovery()
            stopped.removeAll()
            backgrounded.removeAll()
        }
    }

    private func handle(_ data: Data) -> PrivilegedProcessResponse {
        guard data.count <= PrivilegedProcessProtocol.maximumFrameBytes else {
            return failure(.requestTooLarge, "The privileged request is too large.")
        }

        let request: PrivilegedProcessRequest
        do {
            request = try JSONDecoder().decode(PrivilegedProcessRequest.self, from: data)
        } catch {
            return failure(.invalidRequest, "The privileged request is invalid.")
        }
        guard request.processIdentifiers.count <= PrivilegedProcessProtocol.maximumProcessCount,
              request.processes.count <= PrivilegedProcessProtocol.maximumProcessCount else {
            return failure(.tooManyProcesses, "The request contains too many processes.")
        }

        switch request.action {
        case .ping:
            guard request.processIdentifiers.isEmpty, request.processes.isEmpty else {
                return failure(.invalidRequest, "The ping request contains process data.")
            }
            return PrivilegedProcessResponse()
        case .snapshot:
            guard request.processes.isEmpty else {
                return failure(.invalidRequest, "The snapshot request contains identities.")
            }
            let uniquePIDs = Set(request.processIdentifiers).filter {
                $0 > 0
                    && $0 != helperPID
                    && Self.executablePath(for: $0) != helperExecutablePath
            }
            return PrivilegedProcessResponse(
                snapshots: uniquePIDs.compactMap(Self.snapshot).sorted {
                    $0.identity.pid < $1.identity.pid
                }
            )
        case .totalCPUTime:
            return totalCPUTime(for: request)
        case .stop:
            return stop(request)
        case .resume:
            return resume(request)
        case .setBackgroundPriority:
            return setBackgroundPriority(request)
        case .restorePriority:
            return restorePriority(request)
        case .terminate:
            return terminate(request)
        }
    }

    private func totalCPUTime(
        for request: PrivilegedProcessRequest
    ) -> PrivilegedProcessResponse {
        guard let identities = validatedOperationIdentities(request) else {
            return failure(.invalidRequest, "The CPU-time request is invalid.")
        }
        var total: UInt64 = 0
        for process in identities {
            guard Self.currentIdentity(for: process.pid) == process,
                  let snapshot = Self.snapshot(process.pid) else { continue }
            let addition = total.addingReportingOverflow(snapshot.totalCPUTimeNanoseconds)
            guard !addition.overflow else {
                return failure(.operationFailed, "The CPU-time total overflowed.")
            }
            total = addition.partialValue
        }
        return PrivilegedProcessResponse(totalCPUTimeNanoseconds: total)
    }

    private func stop(_ request: PrivilegedProcessRequest) -> PrivilegedProcessResponse {
        guard let identities = validatedOperationIdentities(request) else {
            return failure(.invalidRequest, "The stop request is invalid.")
        }
        let current = Set(identities.filter { Self.currentIdentity(for: $0.pid) == $0 })
        let proposedStopped = stopped.union(current)
        do {
            try watchdog.synchronize(stopped: proposedStopped, backgrounded: backgrounded)
        } catch {
            return failure(.safetyHelperFailed, error.localizedDescription)
        }

        var result = apply(identities) { kill($0, SIGSTOP) }
        stopped.formUnion(result.applied)
        do {
            try watchdog.synchronize(stopped: stopped, backgrounded: backgrounded)
        } catch {
            emergencyRecover()
            result.failed.formUnion(result.applied)
            result.applied.removeAll()
            return response(
                result,
                errorCode: .safetyHelperFailed,
                errorMessage: "Tempra lost its privileged safety process and restored managed processes."
            )
        }
        return response(result)
    }

    private func resume(_ request: PrivilegedProcessRequest) -> PrivilegedProcessResponse {
        guard let identities = validatedOperationIdentities(request) else {
            return failure(.invalidRequest, "The resume request is invalid.")
        }
        let result = apply(identities) { kill($0, SIGCONT) }
        stopped.subtract(result.applied)
        return finishStateChange(result)
    }

    private func setBackgroundPriority(
        _ request: PrivilegedProcessRequest
    ) -> PrivilegedProcessResponse {
        guard let identities = validatedOperationIdentities(request) else {
            return failure(.invalidRequest, "The priority request is invalid.")
        }
        let current = Set(identities.filter { Self.currentIdentity(for: $0.pid) == $0 })
        let proposedBackgrounded = backgrounded.union(current)
        do {
            try watchdog.synchronize(stopped: stopped, backgrounded: proposedBackgrounded)
        } catch {
            return failure(.safetyHelperFailed, error.localizedDescription)
        }
        var result = apply(identities) {
            setpriority(PRIO_DARWIN_PROCESS, id_t($0), PRIO_DARWIN_BG)
        }
        backgrounded.formUnion(result.applied)
        do {
            try watchdog.synchronize(stopped: stopped, backgrounded: backgrounded)
        } catch {
            emergencyRecover()
            result.failed.formUnion(result.applied)
            result.applied.removeAll()
            return response(
                result,
                errorCode: .safetyHelperFailed,
                errorMessage: "Tempra lost its privileged safety process and restored managed processes."
            )
        }
        return response(result)
    }

    private func restorePriority(
        _ request: PrivilegedProcessRequest
    ) -> PrivilegedProcessResponse {
        guard let identities = validatedOperationIdentities(request) else {
            return failure(.invalidRequest, "The priority restore request is invalid.")
        }
        let result = apply(identities) {
            setpriority(PRIO_DARWIN_PROCESS, id_t($0), 0)
        }
        backgrounded.subtract(result.applied)
        return finishStateChange(result)
    }

    private func terminate(_ request: PrivilegedProcessRequest) -> PrivilegedProcessResponse {
        guard let identities = validatedOperationIdentities(request) else {
            return failure(.invalidRequest, "The terminate request is invalid.")
        }
        var result = OperationResult()
        for process in identities {
            guard Self.currentIdentity(for: process.pid) == process else {
                result.stale.insert(process)
                continue
            }
            if stopped.contains(process), kill(process.pid, SIGCONT) != 0 {
                result.failed.insert(process)
                continue
            }
            stopped.remove(process)
            if kill(process.pid, PrivilegedProcessProtocol.forceQuitSignal) == 0 {
                result.applied.insert(process)
                backgrounded.remove(process)
            } else {
                result.failed.insert(process)
            }
        }
        return finishStateChange(result)
    }

    private func finishStateChange(_ result: OperationResult) -> PrivilegedProcessResponse {
        do {
            try watchdog.synchronize(stopped: stopped, backgrounded: backgrounded)
            if stopped.isEmpty, backgrounded.isEmpty {
                watchdog.disarm()
            }
            return response(result)
        } catch {
            emergencyRecover()
            return response(
                OperationResult(failed: result.failed.union(result.applied)),
                errorCode: .safetyHelperFailed,
                errorMessage: "Tempra lost its privileged safety process and restored managed processes."
            )
        }
    }

    private func emergencyRecover() {
        for process in stopped where Self.currentIdentity(for: process.pid) == process {
            _ = kill(process.pid, SIGCONT)
        }
        for process in backgrounded where Self.currentIdentity(for: process.pid) == process {
            _ = setpriority(PRIO_DARWIN_PROCESS, id_t(process.pid), 0)
        }
        stopped.removeAll()
        backgrounded.removeAll()
        watchdog.triggerRecovery()
    }

    private func validatedOperationIdentities(
        _ request: PrivilegedProcessRequest
    ) -> [PrivilegedProcessIdentity]? {
        guard request.processIdentifiers.isEmpty else { return nil }
        let identities = Set(request.processes)
        guard identities.count == request.processes.count,
              Set(identities.map(\.pid)).count == identities.count,
              identities.allSatisfy({
                $0.pid > 1
                    && $0.startTimeMicroseconds > 0
                    && $0.pid != helperPID
                    && Self.executablePath(for: $0.pid) != helperExecutablePath
              }) else {
            return nil
        }
        return identities.sorted(by: Self.identityOrder)
    }

    private func apply(
        _ processes: [PrivilegedProcessIdentity],
        operation: (pid_t) -> Int32
    ) -> OperationResult {
        var result = OperationResult()
        for process in processes {
            guard Self.currentIdentity(for: process.pid) == process else {
                result.stale.insert(process)
                continue
            }
            if operation(process.pid) == 0 {
                result.applied.insert(process)
            } else {
                result.failed.insert(process)
            }
        }
        return result
    }

    private func response(
        _ result: OperationResult,
        errorCode: PrivilegedProcessErrorCode? = nil,
        errorMessage: String? = nil
    ) -> PrivilegedProcessResponse {
        PrivilegedProcessResponse(
            applied: result.applied.sorted(by: Self.identityOrder),
            stale: result.stale.sorted(by: Self.identityOrder),
            failed: result.failed.sorted(by: Self.identityOrder),
            errorCode: errorCode,
            errorMessage: errorMessage
        )
    }

    private func failure(
        _ code: PrivilegedProcessErrorCode,
        _ message: String
    ) -> PrivilegedProcessResponse {
        PrivilegedProcessResponse(errorCode: code, errorMessage: message)
    }

    private static func encode(_ response: PrivilegedProcessResponse) -> Data {
        do {
            let encoded = try JSONEncoder().encode(response)
            guard encoded.count <= PrivilegedProcessProtocol.maximumFrameBytes else {
                return try JSONEncoder().encode(PrivilegedProcessResponse(
                    errorCode: .operationFailed,
                    errorMessage: "The privileged response is too large."
                ))
            }
            return encoded
        } catch {
            return Data(
                "{\"errorCode\":\"operationFailed\",\"errorMessage\":\"The helper could not encode its response.\",\"snapshots\":[],\"applied\":[],\"stale\":[],\"failed\":[],\"totalCPUTimeNanoseconds\":0}".utf8
            )
        }
    }

    private static func snapshot(_ pid: pid_t) -> PrivilegedProcessSnapshot? {
        guard pid > 0 else { return nil }
        var info = proc_taskallinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        let readSize = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, expectedSize)
        let totalTicks = info.ptinfo.pti_total_user.addingReportingOverflow(
            info.ptinfo.pti_total_system
        )
        guard readSize == expectedSize,
              !totalTicks.overflow,
              let identity = identity(from: info.pbsd, pid: pid),
              let totalCPUTimeNanoseconds = nanoseconds(
                fromMachTicks: totalTicks.partialValue
              ) else {
            return nil
        }
        var nameBytes = info.pbsd.pbi_name
        let executableName = withUnsafeBytes(of: &nameBytes) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let executablePath = executablePath(for: pid) ?? ""
        return PrivilegedProcessSnapshot(
            identity: identity,
            parentPID: Int32(info.pbsd.pbi_ppid),
            userID: info.pbsd.pbi_uid,
            executableName: executableName,
            executablePath: executablePath,
            totalCPUTimeNanoseconds: totalCPUTimeNanoseconds,
            residentMemoryBytes: info.ptinfo.pti_resident_size
        )
    }

    private static func currentIdentity(for pid: pid_t) -> PrivilegedProcessIdentity? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard readSize == expectedSize else { return nil }
        return identity(from: info, pid: pid)
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var pathBytes = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(pid, &pathBytes, UInt32(pathBytes.count))
        return pathLength > 0 ? String(cString: pathBytes) : nil
    }

    private static func identity(
        from info: proc_bsdinfo,
        pid: pid_t
    ) -> PrivilegedProcessIdentity? {
        let multiplied = UInt64(info.pbi_start_tvsec).multipliedReportingOverflow(
            by: 1_000_000
        )
        guard !multiplied.overflow else { return nil }
        let added = multiplied.partialValue.addingReportingOverflow(
            UInt64(info.pbi_start_tvusec)
        )
        guard !added.overflow else { return nil }
        return PrivilegedProcessIdentity(
            pid: pid,
            startTimeMicroseconds: added.partialValue
        )
    }

    private static let machTimebase: mach_timebase_info_data_t? = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS,
              info.denom > 0 else { return nil }
        return info
    }()

    private static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64? {
        guard let machTimebase else { return nil }
        let numerator = UInt64(machTimebase.numer)
        let denominator = UInt64(machTimebase.denom)
        let whole = ticks / denominator
        let remainder = ticks % denominator
        let wholeProduct = whole.multipliedReportingOverflow(by: numerator)
        let remainderProduct = remainder.multipliedReportingOverflow(by: numerator)
        guard !wholeProduct.overflow, !remainderProduct.overflow else { return nil }
        let total = wholeProduct.partialValue.addingReportingOverflow(
            remainderProduct.partialValue / denominator
        )
        return total.overflow ? nil : total.partialValue
    }

    private static func identityOrder(
        _ first: PrivilegedProcessIdentity,
        _ second: PrivilegedProcessIdentity
    ) -> Bool {
        if first.pid != second.pid { return first.pid < second.pid }
        return first.startTimeMicroseconds < second.startTimeMicroseconds
    }

    private struct OperationResult {
        var applied: Set<PrivilegedProcessIdentity> = []
        var stale: Set<PrivilegedProcessIdentity> = []
        var failed: Set<PrivilegedProcessIdentity> = []
    }
}

private final class PrivilegedHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let lock = NSLock()
    private let executableURL: URL
    private var activeConnection: NSXPCConnection?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        var consoleInfo = stat()
        guard stat("/dev/console", &consoleInfo) == 0,
              consoleInfo.st_uid != 0,
              connection.effectiveUserIdentifier == consoleInfo.st_uid else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        guard activeConnection == nil else { return false }

        let session = PrivilegedProcessSession(executableURL: executableURL)
        connection.exportedInterface = NSXPCInterface(
            with: PrivilegedProcessXPCProtocol.self
        )
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self, weak connection] in
            session.invalidate()
            guard let self else { return }
            lock.lock()
            if activeConnection === connection {
                activeConnection = nil
            }
            lock.unlock()
        }
        activeConnection = connection
        connection.activate()
        return true
    }
}

@main
private enum TempraPrivilegedHelperMain {
    private static let logger = Logger(
        subsystem: PrivilegedProcessProtocol.applicationIdentifier,
        category: "PrivilegedHelper"
    )

    static func main() {
        if CommandLine.arguments.dropFirst().first == "--watchdog" {
            exit(runWatchdog())
        }

        guard geteuid() == 0 else {
            logger.fault("The privileged helper did not start as root.")
            exit(EXIT_FAILURE)
        }
        guard let executableURL = currentExecutableURL() else {
            logger.fault("The privileged helper could not resolve its executable path.")
            exit(EXIT_FAILURE)
        }

        let listener = NSXPCListener(
            machServiceName: PrivilegedProcessProtocol.machServiceName
        )
        do {
            listener.setConnectionCodeSigningRequirement(
                try TempraCodeSigningRequirement.peerRequirement(
                    identifier: PrivilegedProcessProtocol.applicationIdentifier
                )
            )
        } catch {
            logger.fault(
                "The privileged helper could not create its client requirement: \(error.localizedDescription, privacy: .public)"
            )
            exit(EXIT_FAILURE)
        }
        let delegate = PrivilegedHelperListenerDelegate(executableURL: executableURL)
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime(delegate) {
            dispatchMain()
        }
    }

    private static func runWatchdog() -> Int32 {
        var stream = PrivilegedWatchdogStream()
        var state = PrivilegedWatchdogState(stopped: [], backgrounded: [])
        while true {
            let data: Data
            do {
                data = try FileHandle.standardInput.read(upToCount: 4_096) ?? Data()
            } catch {
                return recover(state) ? EXIT_FAILURE : 3
            }
            guard !data.isEmpty else {
                do {
                    try stream.finish()
                } catch {
                    return recover(state) ? EXIT_FAILURE : 3
                }
                return recover(state) ? EXIT_SUCCESS : 3
            }
            do {
                for update in try stream.append(data) {
                    state = update
                }
            } catch {
                return recover(state) ? EXIT_FAILURE : 3
            }
        }
    }

    private static func recover(_ state: PrivilegedWatchdogState) -> Bool {
        var succeeded = true
        for process in state.stopped {
            guard currentIdentity(for: process.pid) == process else { continue }
            if kill(process.pid, SIGCONT) != 0 { succeeded = false }
        }
        for process in state.backgrounded {
            guard currentIdentity(for: process.pid) == process else { continue }
            if setpriority(PRIO_DARWIN_PROCESS, id_t(process.pid), 0) != 0 {
                succeeded = false
            }
        }
        return succeeded
    }

    private static func currentIdentity(for pid: pid_t) -> WatchdogProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard readSize == expectedSize else { return nil }
        let multiplied = UInt64(info.pbi_start_tvsec).multipliedReportingOverflow(
            by: 1_000_000
        )
        guard !multiplied.overflow else { return nil }
        let added = multiplied.partialValue.addingReportingOverflow(
            UInt64(info.pbi_start_tvusec)
        )
        guard !added.overflow else { return nil }
        return WatchdogProcessIdentity(
            pid: pid,
            startTimeMicroseconds: added.partialValue
        )
    }

    private static func currentExecutableURL() -> URL? {
        var pathBytes = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(getpid(), &pathBytes, UInt32(pathBytes.count))
        guard pathLength > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: pathBytes)).standardizedFileURL
    }
}
