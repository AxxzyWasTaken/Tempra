import Darwin
import Foundation
import TempraSafety

struct ProcessOperationResult: Equatable, Sendable {
    var applied: Set<ProcessIdentity> = []
    var stale: Set<ProcessIdentity> = []
    var failed: Set<ProcessIdentity> = []

    var succeeded: Bool {
        !applied.isEmpty && failed.isEmpty
    }
}

private enum ProcessSystemControllerError: LocalizedError {
    case arithmeticOverflow

    var errorDescription: String? {
        "A process CPU-time counter overflowed."
    }
}

protocol ProcessSystemControlling: Sendable {
    func totalCPUTime(for processes: Set<ProcessIdentity>) async throws -> UInt64
    func networkActivity(for process: ProcessIdentity) async -> ProcessNetworkActivity
    func criticalFileActivity(
        for process: ProcessIdentity
    ) async -> ProcessCriticalFileActivity
    func stop(
        _ processes: Set<ProcessIdentity>,
        automaticResumeAfter: TimeInterval?
    ) async -> ProcessOperationResult
    func resume(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult
    func setBackgroundPriority(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult
    func restorePriority(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult
    func terminate(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult
}

struct LiveProcessSystemController: ProcessSystemControlling {
    func totalCPUTime(for processes: Set<ProcessIdentity>) async throws -> UInt64 {
        var total: UInt64 = 0
        for process in processes {
            guard Self.currentIdentity(for: process.pid) == process,
                  let counter = Self.cpuTimeNanoseconds(for: process.pid) else {
                continue
            }
            let sum = total.addingReportingOverflow(counter)
            guard !sum.overflow else {
                throw ProcessSystemControllerError.arithmeticOverflow
            }
            total = sum.partialValue
        }
        return total
    }

    func networkActivity(for process: ProcessIdentity) async -> ProcessNetworkActivity {
        await ProcessNetworkActivityProbe().activityWithoutBlockingController(for: process)
    }

    func criticalFileActivity(
        for process: ProcessIdentity
    ) async -> ProcessCriticalFileActivity {
        await ProcessCriticalFileActivityProbe().activityWithoutBlockingController(for: process)
    }

    func stop(
        _ processes: Set<ProcessIdentity>,
        automaticResumeAfter: TimeInterval?
    ) async -> ProcessOperationResult {
        apply(processes) { kill($0, SIGSTOP) }
    }

    func resume(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        apply(processes) { kill($0, SIGCONT) }
    }

    func setBackgroundPriority(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        ProcessOperationResult(failed: processes)
    }

    func restorePriority(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        ProcessOperationResult(failed: processes)
    }

    func terminate(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        apply(processes) { kill($0, PrivilegedProcessProtocol.forceQuitSignal) }
    }

    private func apply(
        _ processes: Set<ProcessIdentity>,
        operation: (pid_t) -> Int32
    ) -> ProcessOperationResult {
        var result = ProcessOperationResult()
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

    static func currentIdentity(for pid: pid_t) -> ProcessIdentity? {
        guard pid > 1 else { return nil }
        guard let info = bsdInfo(for: pid) else { return nil }
        let seconds = UInt64(info.pbi_start_tvsec)
        let microseconds = UInt64(info.pbi_start_tvusec)
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !multiplied.overflow else { return nil }
        let added = multiplied.partialValue.addingReportingOverflow(microseconds)
        guard !added.overflow else { return nil }
        return ProcessIdentity(
            pid: pid,
            startTimeMicroseconds: added.partialValue
        )
    }

    static func bsdInfo(for pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        return readSize == expectedSize ? info : nil
    }

    static func cpuTimeNanoseconds(for pid: pid_t) -> UInt64? {
        var taskInfo = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let readSize = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, expectedSize)
        guard readSize == expectedSize else { return nil }
        let totalTicks = taskInfo.pti_total_user.addingReportingOverflow(
            taskInfo.pti_total_system
        )
        guard !totalTicks.overflow else { return nil }
        return nanoseconds(fromMachTicks: totalTicks.partialValue)
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
}

struct RoutedProcessSystemController: ProcessSystemControlling {
    private let local: LiveProcessSystemController
    private let privileged: PrivilegedProcessClient

    init(
        local: LiveProcessSystemController = LiveProcessSystemController(),
        privileged: PrivilegedProcessClient = .shared
    ) {
        self.local = local
        self.privileged = privileged
    }

    func totalCPUTime(for processes: Set<ProcessIdentity>) async throws -> UInt64 {
        let (localProcesses, privilegedProcesses) = partition(processes)
        let localTotal = try await local.totalCPUTime(for: localProcesses)
        guard !privilegedProcesses.isEmpty else { return localTotal }
        let privilegedTotal = try await privileged.totalCPUTime(for: privilegedProcesses)
        let sum = localTotal.addingReportingOverflow(privilegedTotal)
        guard !sum.overflow else {
            throw PrivilegedProcessClientError.remoteFailure(
                "The combined CPU-time counter overflowed."
            )
        }
        return sum.partialValue
    }

    func networkActivity(for process: ProcessIdentity) async -> ProcessNetworkActivity {
        await local.networkActivity(for: process)
    }

    func criticalFileActivity(
        for process: ProcessIdentity
    ) async -> ProcessCriticalFileActivity {
        await local.criticalFileActivity(for: process)
    }

    func stop(
        _ processes: Set<ProcessIdentity>,
        automaticResumeAfter: TimeInterval?
    ) async -> ProcessOperationResult {
        await apply(
            .stop,
            to: processes,
            automaticResumeAfter: automaticResumeAfter
        ) {
            await local.stop($0, automaticResumeAfter: automaticResumeAfter)
        }
    }

    func resume(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        await apply(.resume, to: processes) { await local.resume($0) }
    }

    func setBackgroundPriority(
        _ processes: Set<ProcessIdentity>
    ) async -> ProcessOperationResult {
        await applyPrivileged(.setBackgroundPriority, to: processes)
    }

    func restorePriority(
        _ processes: Set<ProcessIdentity>
    ) async -> ProcessOperationResult {
        await applyPrivileged(.restorePriority, to: processes)
    }

    func terminate(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        await apply(.terminate, to: processes) { await local.terminate($0) }
    }

    private func apply(
        _ action: PrivilegedProcessAction,
        to processes: Set<ProcessIdentity>,
        automaticResumeAfter: TimeInterval? = nil,
        localOperation: (Set<ProcessIdentity>) async -> ProcessOperationResult
    ) async -> ProcessOperationResult {
        let (localProcesses, privilegedProcesses) = partition(processes)
        var result = await localOperation(localProcesses)
        guard !privilegedProcesses.isEmpty else { return result }
        do {
            let privilegedResult = try await privileged.perform(
                action,
                processes: privilegedProcesses,
                automaticResumeAfter: automaticResumeAfter
            )
            result.applied.formUnion(privilegedResult.applied)
            result.stale.formUnion(privilegedResult.stale)
            result.failed.formUnion(privilegedResult.failed)
        } catch {
            result.failed.formUnion(privilegedProcesses)
        }
        return result
    }

    private func applyPrivileged(
        _ action: PrivilegedProcessAction,
        to processes: Set<ProcessIdentity>
    ) async -> ProcessOperationResult {
        guard !processes.isEmpty else { return ProcessOperationResult() }
        do {
            return try await privileged.perform(action, processes: processes)
        } catch {
            return ProcessOperationResult(failed: processes)
        }
    }

    private func partition(
        _ processes: Set<ProcessIdentity>
    ) -> (local: Set<ProcessIdentity>, privileged: Set<ProcessIdentity>) {
        let privileged = processes.filter(\.requiresPrivilegedControl)
        return (processes.subtracting(privileged), Set(privileged))
    }
}
