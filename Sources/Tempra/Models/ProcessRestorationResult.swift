import Foundation

struct ProcessRestorationFailure: Equatable, Sendable {
    let bundleIdentifier: String
    let stoppedProcesses: Set<ProcessIdentity>
    let backgroundPriorityProcesses: Set<ProcessIdentity>
    let resumeFailureDescription: String?
    let priorityFailureDescription: String?

    init(
        bundleIdentifier: String,
        stoppedProcesses: Set<ProcessIdentity>,
        backgroundPriorityProcesses: Set<ProcessIdentity>,
        resumeFailureDescription: String? = nil,
        priorityFailureDescription: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.stoppedProcesses = stoppedProcesses
        self.backgroundPriorityProcesses = backgroundPriorityProcesses
        self.resumeFailureDescription = resumeFailureDescription
        self.priorityFailureDescription = priorityFailureDescription
    }

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
