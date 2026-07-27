import Darwin
import Foundation

struct ProcessOperationResult: Equatable, Sendable {
    var applied: Set<ProcessIdentity> = []
    var stale: Set<ProcessIdentity> = []
    var failed: Set<ProcessIdentity> = []

    var succeeded: Bool {
        !applied.isEmpty && failed.isEmpty
    }
}
protocol ProcessSystemControlling: Sendable {
    func totalCPUTime(for processes: Set<ProcessIdentity>) -> UInt64
    func stop(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult
    func resume(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult
    func setBackgroundPriority(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult
    func restorePriority(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult
}

struct LiveProcessSystemController: ProcessSystemControlling {
    func totalCPUTime(for processes: Set<ProcessIdentity>) -> UInt64 {
        processes.reduce(0) { total, process in
            guard Self.currentIdentity(for: process.pid) == process,
                  let counter = Self.cpuTimeNanoseconds(for: process.pid) else {
                return total
            }
            return total &+ counter
        }
    }

    func stop(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        apply(processes) { kill($0, SIGSTOP) }
    }

    func resume(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        apply(processes) { kill($0, SIGCONT) }
    }

    func setBackgroundPriority(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        apply(processes) {
            setpriority(PRIO_DARWIN_PROCESS, id_t($0), PRIO_DARWIN_BG)
        }
    }

    func restorePriority(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        apply(processes) {
            setpriority(PRIO_DARWIN_PROCESS, id_t($0), 0)
        }
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
        guard let info = bsdInfo(for: pid) else { return nil }
        return ProcessIdentity(
            pid: pid,
            startTimeMicroseconds: UInt64(info.pbi_start_tvsec) * 1_000_000
                + UInt64(info.pbi_start_tvusec)
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
        return nanoseconds(
            fromMachTicks: taskInfo.pti_total_user &+ taskInfo.pti_total_system
        )
    }

    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        _ = mach_timebase_info(&info)
        return info
    }()

    private static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        let numerator = UInt64(machTimebase.numer)
        let denominator = UInt64(machTimebase.denom)
        guard denominator > 0 else { return ticks }

        let whole = ticks / denominator
        let remainder = ticks % denominator
        return whole * numerator + (remainder * numerator) / denominator
    }
}
