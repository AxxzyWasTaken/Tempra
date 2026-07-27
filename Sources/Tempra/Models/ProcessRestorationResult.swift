import Foundation

struct ProcessRestorationFailure: Equatable, Sendable {
    let bundleIdentifier: String
    let stoppedProcesses: Set<ProcessIdentity>
    let backgroundPriorityProcesses: Set<ProcessIdentity>

    var processIdentifiers: [pid_t] {
        Set(stoppedProcesses.map(\.pid) + backgroundPriorityProcesses.map(\.pid)).sorted()
    }
}

struct ProcessRestorationResult: Equatable, Sendable {
    let failures: [ProcessRestorationFailure]

    var succeeded: Bool {
        failures.isEmpty
    }

    static let success = ProcessRestorationResult(failures: [])
}
