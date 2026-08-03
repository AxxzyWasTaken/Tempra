import Foundation

enum ProcessRestorationState {
    static func result(
        stoppedByIdentifier: [String: Set<ProcessIdentity>],
        backgroundedByIdentifier: [String: Set<ProcessIdentity>]
    ) -> ProcessRestorationResult {
        let identifiers = Set(stoppedByIdentifier.keys).union(backgroundedByIdentifier.keys)
        let failures = identifiers.compactMap { identifier -> ProcessRestorationFailure? in
            let stopped = stoppedByIdentifier[identifier, default: []]
            let backgrounded = backgroundedByIdentifier[identifier, default: []]
            guard !stopped.isEmpty || !backgrounded.isEmpty else { return nil }
            return ProcessRestorationFailure(
                bundleIdentifier: identifier,
                stoppedProcesses: stopped,
                backgroundPriorityProcesses: backgrounded
            )
        }.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        return ProcessRestorationResult(failures: failures)
    }
}
