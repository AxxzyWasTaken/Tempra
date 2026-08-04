import Foundation

struct ProcessLimitSelection: Equatable, Sendable {
    let controlledProcesses: Set<ProcessIdentity>
    let alwaysRunningProcesses: Set<ProcessIdentity>
    let controlledCPUPercent: Double
    let alwaysRunningCPUPercent: Double
    let controlledLimitPercent: Double
    let targetIsReachable: Bool

    static let empty = ProcessLimitSelection(
        controlledProcesses: [],
        alwaysRunningProcesses: [],
        controlledCPUPercent: 0,
        alwaysRunningCPUPercent: 0,
        controlledLimitPercent: 0,
        targetIsReachable: true
    )
}

enum ProcessLimitTargetSelector {
    static func select(
        samples: [ManagedProcessSample],
        limitPercent: Double,
        previousControlledProcesses: Set<ProcessIdentity> = []
    ) -> ProcessLimitSelection {
        let requestedLimit = limitPercent.isFinite ? max(0, limitPercent) : 0
        let samplesByIdentity = samples.reduce(into: [ProcessIdentity: ManagedProcessSample]()) {
            result, sample in
            result[sample.identity] = sample
        }
        let normalizedSamples = samplesByIdentity.values.sorted {
            $0.identity.pid < $1.identity.pid
        }
        guard !normalizedSamples.isEmpty else { return .empty }

        var alwaysRunning = Set(normalizedSamples.compactMap { sample in
            sample.isPlayingAudio
                || sample.networkActivity.protectsFromLimiting
                || !sample.hasCPUMeasurement
                ? sample.identity
                : nil
        })

        if normalizedSamples.count > 1 {
            let mainLifeline = normalizedSamples
                .filter(\.isMainProcess)
                .min(by: sampleOrderByCPUThenIdentity)
                ?? normalizedSamples.min(by: sampleOrderByCPUThenIdentity)
            if let mainLifeline {
                alwaysRunning.insert(mainLifeline.identity)
            }
        }

        let totalCPU = normalizedSamples.reduce(0) { $0 + $1.cpuPercent }
        let activationThreshold = ProcessControlMath.activationThreshold(for: requestedLimit)
        guard normalizedSamples.count == 1 || totalCPU > activationThreshold else {
            return makeSelection(
                controlled: [],
                samples: normalizedSamples,
                requestedLimit: requestedLimit
            )
        }

        let eligible = normalizedSamples.filter {
            !alwaysRunning.contains($0.identity) && $0.cpuPercent > 0
        }
        guard !eligible.isEmpty else {
            return makeSelection(
                controlled: [],
                samples: normalizedSamples,
                requestedLimit: requestedLimit
            )
        }

        if normalizedSamples.count == 1, let onlyProcess = eligible.first {
            return makeSelection(
                controlled: [onlyProcess.identity],
                samples: normalizedSamples,
                requestedLimit: requestedLimit
            )
        }

        let previousEligible = previousControlledProcesses.intersection(
            Set(eligible.map(\.identity))
        )
        if !previousEligible.isEmpty {
            let previousControlledCPU = eligible.reduce(0) { result, sample in
                result + (previousEligible.contains(sample.identity) ? sample.cpuPercent : 0)
            }
            let previousAlwaysRunningCPU = max(0, totalCPU - previousControlledCPU)
            if previousAlwaysRunningCPU <= activationThreshold {
                return makeSelection(
                    controlled: previousEligible,
                    samples: normalizedSamples,
                    requestedLimit: requestedLimit
                )
            }
        }

        let orderedCandidates = eligible.sorted { first, second in
            if first.cpuPercent != second.cpuPercent {
                return first.cpuPercent > second.cpuPercent
            }
            let firstWasControlled = previousControlledProcesses.contains(first.identity)
            let secondWasControlled = previousControlledProcesses.contains(second.identity)
            if firstWasControlled != secondWasControlled {
                return firstWasControlled
            }
            return first.identity.pid < second.identity.pid
        }

        var controlled: Set<ProcessIdentity> = []
        var controlledCPU = 0.0
        for sample in orderedCandidates {
            guard totalCPU - controlledCPU > requestedLimit else { break }
            controlled.insert(sample.identity)
            controlledCPU += sample.cpuPercent
        }

        return makeSelection(
            controlled: controlled,
            samples: normalizedSamples,
            requestedLimit: requestedLimit
        )
    }

    private static func makeSelection(
        controlled: Set<ProcessIdentity>,
        samples: [ManagedProcessSample],
        requestedLimit: Double
    ) -> ProcessLimitSelection {
        let controlledCPU = samples.reduce(0) { result, sample in
            result + (controlled.contains(sample.identity) ? sample.cpuPercent : 0)
        }
        let totalCPU = samples.reduce(0) { $0 + $1.cpuPercent }
        let alwaysRunningCPU = max(0, totalCPU - controlledCPU)
        let allIdentities = Set(samples.map(\.identity))
        let controlledLimit = min(
            controlledCPU,
            max(0, requestedLimit - alwaysRunningCPU)
        )
        return ProcessLimitSelection(
            controlledProcesses: controlled,
            alwaysRunningProcesses: allIdentities.subtracting(controlled),
            controlledCPUPercent: controlledCPU,
            alwaysRunningCPUPercent: alwaysRunningCPU,
            controlledLimitPercent: controlledLimit,
            targetIsReachable: alwaysRunningCPU <= requestedLimit
        )
    }

    private static func sampleOrderByCPUThenIdentity(
        _ first: ManagedProcessSample,
        _ second: ManagedProcessSample
    ) -> Bool {
        if first.cpuPercent != second.cpuPercent {
            return first.cpuPercent < second.cpuPercent
        }
        return first.identity.pid < second.identity.pid
    }
}
