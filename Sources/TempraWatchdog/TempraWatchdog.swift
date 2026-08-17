import Darwin
import Foundation
import TempraSafety

@main
enum TempraWatchdogMain {
    private static let readChunkSize = 4_096
    private static let resumeAttempts = 3
    private static let recoveryRetryMicroseconds: useconds_t = 100_000
    private static let deadlineRetryMicroseconds: useconds_t = 10_000

    private struct AutomaticResumeState {
        var deadline: ContinuousClock.Instant
        let intervalMilliseconds: UInt32
    }

    static func main() {
        if CommandLine.arguments.dropFirst().first == "--stdio" {
            exit(run())
        }
        exit(ProcessGuardianService.run())
    }

    private static func run() -> Int32 {
        guard fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) == 0 else { return 5 }
        var stream = WatchdogCommandStream()
        var trackedProcesses: Set<WatchdogProcessIdentity> = []
        var automaticResumeStates: [WatchdogProcessIdentity: AutomaticResumeState] = [:]
        var inputBytes = [UInt8](repeating: 0, count: readChunkSize)
        let clock = ContinuousClock()

        while true {
            guard resumeExpiredProcesses(
                in: &automaticResumeStates,
                now: clock.now
            ) else {
                return recover(trackedProcesses) ? 4 : 3
            }

            var input = pollfd(
                fd: STDIN_FILENO,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = poll(
                &input,
                1,
                pollTimeoutMilliseconds(for: automaticResumeStates, now: clock.now)
            )
            if pollResult < 0 {
                if errno == EINTR { continue }
                return recover(trackedProcesses) ? 2 : 3
            }
            if pollResult == 0 { continue }
            if input.revents & Int16(POLLNVAL) != 0 {
                return recover(trackedProcesses) ? 2 : 3
            }

            let readCount = inputBytes.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.read(STDIN_FILENO, baseAddress, buffer.count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                return recover(trackedProcesses) ? 2 : 3
            }
            guard readCount <= inputBytes.count else {
                return recover(trackedProcesses) ? 2 : 3
            }
            let data = Data(inputBytes.prefix(readCount))

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
                    automaticResumeStates = automaticResumeStates.filter {
                        trackedProcesses.contains($0.key)
                    }
                case .armResume:
                    let processes = Set(command.resumeDeadlines.map(\.process))
                    guard processes.isSubset(of: trackedProcesses) else {
                        return recover(trackedProcesses) ? 2 : 3
                    }
                    let armedAt = clock.now
                    for entry in command.resumeDeadlines {
                        let deadline = armedAt.advanced(
                            by: .milliseconds(Int64(entry.resumeAfterMilliseconds))
                        )
                        automaticResumeStates[entry.process] = AutomaticResumeState(
                            deadline: deadline,
                            intervalMilliseconds: entry.resumeAfterMilliseconds
                        )
                    }
                    guard acknowledgeAutomaticResumeArm() else {
                        return recover(trackedProcesses) ? 2 : 3
                    }
                case .synchronizeResume:
                    let processes = Set(command.resumeDeadlines.map(\.process))
                    guard processes.isSubset(of: trackedProcesses) else {
                        return recover(trackedProcesses) ? 2 : 3
                    }
                    automaticResumeStates = automaticResumeStates.filter {
                        processes.contains($0.key)
                    }
                    let synchronizedAt = clock.now
                    for entry in command.resumeDeadlines {
                        let deadline = synchronizedAt.advanced(
                            by: .milliseconds(Int64(entry.resumeAfterMilliseconds))
                        )
                        if let state = automaticResumeStates[entry.process] {
                            automaticResumeStates[entry.process] = AutomaticResumeState(
                                deadline: state.deadline,
                                intervalMilliseconds: entry.resumeAfterMilliseconds
                            )
                        } else {
                            automaticResumeStates[entry.process] = AutomaticResumeState(
                                deadline: deadline,
                                intervalMilliseconds: entry.resumeAfterMilliseconds
                            )
                        }
                    }
                case .disarm:
                    return 0
                }
            }
        }
    }

    private static func recover(_ processes: Set<WatchdogProcessIdentity>) -> Bool {
        unresolvedAfterResume(
            processes,
            attempts: resumeAttempts,
            retryMicroseconds: recoveryRetryMicroseconds
        ).isEmpty
    }

    private static func acknowledgeAutomaticResumeArm() -> Bool {
        do {
            try FileHandle.standardOutput.write(contentsOf: Data([
                WatchdogAcknowledgement.automaticResumeArmed,
            ]))
            return true
        } catch {
            return false
        }
    }

    private static func resumeExpiredProcesses(
        in states: inout [WatchdogProcessIdentity: AutomaticResumeState],
        now: ContinuousClock.Instant
    ) -> Bool {
        let expired = Set(states.compactMap { process, state in
            state.deadline <= now ? process : nil
        })
        guard !expired.isEmpty else { return true }

        let unresolved = unresolvedAfterResume(
            expired,
            attempts: resumeAttempts,
            retryMicroseconds: deadlineRetryMicroseconds
        )
        guard unresolved.isEmpty else { return false }

        let resumedAt = ContinuousClock().now
        for process in expired {
            guard let state = states[process] else { continue }
            states[process] = AutomaticResumeState(
                deadline: resumedAt.advanced(
                    by: .milliseconds(Int64(state.intervalMilliseconds))
                ),
                intervalMilliseconds: state.intervalMilliseconds
            )
        }
        return true
    }

    private static func unresolvedAfterResume(
        _ processes: Set<WatchdogProcessIdentity>,
        attempts: Int,
        retryMicroseconds: useconds_t
    ) -> Set<WatchdogProcessIdentity> {
        var unresolved = Set(processes.filter { currentIdentity(for: $0.pid) == $0 })
        for attempt in 0..<attempts where !unresolved.isEmpty {
            unresolved = Set(unresolved.filter { process in
                guard currentIdentity(for: process.pid) == process else { return false }
                return kill(process.pid, SIGCONT) != 0
            })
            if !unresolved.isEmpty, attempt + 1 < attempts {
                usleep(retryMicroseconds)
            }
        }
        return unresolved
    }

    private static func pollTimeoutMilliseconds(
        for states: [WatchdogProcessIdentity: AutomaticResumeState],
        now: ContinuousClock.Instant
    ) -> Int32 {
        guard let deadline = states.values.lazy.map(\.deadline).min() else { return -1 }
        let remaining = now.duration(to: deadline)
        guard remaining > .zero else { return 0 }

        let components = remaining.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let milliseconds = ceil(seconds * 1_000)
        guard milliseconds.isFinite, milliseconds < Double(Int32.max) else {
            return Int32.max
        }
        return max(1, Int32(milliseconds))
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
