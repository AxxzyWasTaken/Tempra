import Darwin
import Foundation
import TempraSafety

@main
enum TempraWatchdogMain {
    private static let readChunkSize = 4_096
    private static let resumeAttempts = 3

    static func main() {
        exit(run())
    }

    private static func run() -> Int32 {
        var stream = WatchdogCommandStream()
        var trackedProcesses: Set<WatchdogProcessIdentity> = []

        while true {
            let data: Data
            do {
                data = try FileHandle.standardInput.read(upToCount: readChunkSize) ?? Data()
            } catch {
                return recover(trackedProcesses) ? 2 : 3
            }

            guard !data.isEmpty else {
                do {
                    try stream.finish()
                } catch {
                    return recover(trackedProcesses) ? 2 : 3
                }
                return recover(trackedProcesses) ? 0 : 3
            }

            let commands: [WatchdogCommand]
            do {
                commands = try stream.append(data)
            } catch {
                return recover(trackedProcesses) ? 2 : 3
            }

            for command in commands {
                switch command.action {
                case .update:
                    trackedProcesses = Set(command.processes)
                case .disarm:
                    return 0
                }
            }
        }
    }

    private static func recover(_ processes: Set<WatchdogProcessIdentity>) -> Bool {
        var unresolved = processes.filter { currentIdentity(for: $0.pid) == $0 }
        for attempt in 0..<resumeAttempts where !unresolved.isEmpty {
            unresolved = unresolved.filter { process in
                guard currentIdentity(for: process.pid) == process else { return false }
                return kill(process.pid, SIGCONT) != 0
            }
            if !unresolved.isEmpty, attempt + 1 < resumeAttempts {
                usleep(100_000)
            }
        }
        return unresolved.isEmpty
    }

    private static func currentIdentity(for pid: pid_t) -> WatchdogProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard readSize == expectedSize else { return nil }

        let seconds = UInt64(info.pbi_start_tvsec)
        let microseconds = UInt64(info.pbi_start_tvusec)
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !multiplied.overflow else { return nil }
        let added = multiplied.partialValue.addingReportingOverflow(microseconds)
        guard !added.overflow else { return nil }
        return WatchdogProcessIdentity(
            pid: pid,
            startTimeMicroseconds: added.partialValue
        )
    }
}
