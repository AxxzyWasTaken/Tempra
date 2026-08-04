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
        previousControlledProcesses: Set<ProcessIdentity> = [],
        latencySensitiveProcesses: Set<ProcessIdentity> = [],
        criticalActivityProcesses: Set<ProcessIdentity> = [],
        protectsAudio: Bool = true,
        minimumControlledDutyCycle: Double = 0
    ) -> ProcessLimitSelection {
        let requestedLimit = limitPercent.isFinite ? max(0, limitPercent) : 0
        let normalizedMinimumDutyCycle = minimumControlledDutyCycle.isFinite
            ? min(1, max(0, minimumControlledDutyCycle))
            : 0
        let samplesByIdentity = samples.reduce(into: [ProcessIdentity: ManagedProcessSample]()) {
            result, sample in
            result[sample.identity] = sample
        }
        let normalizedSamples = samplesByIdentity.values.sorted {
            $0.identity.pid < $1.identity.pid
        }
        guard !normalizedSamples.isEmpty else { return .empty }

        let hardProtectedProcesses = Set(normalizedSamples.compactMap { sample in
            !sample.hasCPUMeasurement
                || (protectsAudio && sample.isPlayingAudio)
                || criticalActivityProcesses.contains(sample.identity)
                ? sample.identity
                : nil
        })
        var softProtectedProcesses = Set(normalizedSamples.compactMap { sample in
            sample.networkActivity.isLatencySensitive ? sample.identity : nil
        })
        softProtectedProcesses.formUnion(
            latencySensitiveProcesses.intersection(samplesByIdentity.keys)
        )

        if normalizedSamples.count > 1 {
            let mainLifeline = normalizedSamples
                .filter(\.isMainProcess)
                .min(by: sampleOrderByCPUThenIdentity)
                ?? normalizedSamples.min(by: sampleOrderByCPUThenIdentity)
            if let mainLifeline {
                softProtectedProcesses.insert(mainLifeline.identity)
            }
        }

        let totalCPU = normalizedSamples.reduce(0) { $0 + $1.cpuPercent }
        let activationThreshold = ProcessControlMath.activationThreshold(for: requestedLimit)
        guard normalizedSamples.count == 1 || totalCPU > activationThreshold else {
            return makeSelection(
                controlled: [],
                samples: normalizedSamples,
                requestedLimit: requestedLimit,
                minimumControlledDutyCycle: normalizedMinimumDutyCycle
            )
        }

        let eligible = normalizedSamples.filter {
            !hardProtectedProcesses.contains($0.identity) && $0.cpuPercent > 0
        }
        guard !eligible.isEmpty else {
            return makeSelection(
                controlled: [],
                samples: normalizedSamples,
                requestedLimit: requestedLimit,
                minimumControlledDutyCycle: normalizedMinimumDutyCycle
            )
        }

        if normalizedSamples.count == 1, let onlyProcess = eligible.first {
            return makeSelection(
                controlled: [onlyProcess.identity],
                samples: normalizedSamples,
                requestedLimit: requestedLimit,
                minimumControlledDutyCycle: normalizedMinimumDutyCycle
            )
        }

        let hardProtectedCPU = normalizedSamples.reduce(0) { result, sample in
            result + (hardProtectedProcesses.contains(sample.identity) ? sample.cpuPercent : 0)
        }
        let selectionThreshold = ProcessControlMath.activationThreshold(
            for: max(requestedLimit, hardProtectedCPU)
        )
        let preferredCandidates = eligible.filter {
            !softProtectedProcesses.contains($0.identity)
        }
        let preferredControlled = selectCandidates(
            preferredCandidates,
            totalCPU: totalCPU,
            stopThreshold: selectionThreshold,
            previousControlledProcesses: previousControlledProcesses,
            softProtectedProcesses: softProtectedProcesses
        )
        let preferredControlledCPU = normalizedSamples.reduce(0) { result, sample in
            result + (preferredControlled.contains(sample.identity) ? sample.cpuPercent : 0)
        }
        if totalCPU - preferredControlledCPU <= selectionThreshold {
            return makeSelection(
                controlled: preferredControlled,
                samples: normalizedSamples,
                requestedLimit: requestedLimit,
                minimumControlledDutyCycle: normalizedMinimumDutyCycle
            )
        }

        let controlled = selectCandidates(
            eligible,
            totalCPU: totalCPU,
            stopThreshold: selectionThreshold,
            previousControlledProcesses: previousControlledProcesses,
            softProtectedProcesses: softProtectedProcesses
        )

        return makeSelection(
            controlled: controlled,
            samples: normalizedSamples,
            requestedLimit: requestedLimit,
            minimumControlledDutyCycle: normalizedMinimumDutyCycle
        )
    }

    private static func selectCandidates(
        _ candidates: [ManagedProcessSample],
        totalCPU: Double,
        stopThreshold: Double,
        previousControlledProcesses: Set<ProcessIdentity>,
        softProtectedProcesses: Set<ProcessIdentity>
    ) -> Set<ProcessIdentity> {
        let candidateIdentities = Set(candidates.map(\.identity))
        let previousEligible = previousControlledProcesses.intersection(candidateIdentities)
        if !previousEligible.isEmpty {
            let previousControlledCPU = candidates.reduce(0) { result, sample in
                result + (previousEligible.contains(sample.identity) ? sample.cpuPercent : 0)
            }
            if totalCPU - previousControlledCPU <= stopThreshold {
                return previousEligible
            }
        }

        let orderedCandidates = candidates.sorted { first, second in
            if first.cpuPercent != second.cpuPercent {
                return first.cpuPercent > second.cpuPercent
            }
            let firstIsSoftProtected = softProtectedProcesses.contains(first.identity)
            let secondIsSoftProtected = softProtectedProcesses.contains(second.identity)
            if firstIsSoftProtected != secondIsSoftProtected {
                return !firstIsSoftProtected
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
            guard totalCPU - controlledCPU > stopThreshold else { break }
            controlled.insert(sample.identity)
            controlledCPU += sample.cpuPercent
        }
        return controlled
    }

    private static func makeSelection(
        controlled: Set<ProcessIdentity>,
        samples: [ManagedProcessSample],
        requestedLimit: Double,
        minimumControlledDutyCycle: Double
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
        let minimumControlledCPU = controlledCPU * minimumControlledDutyCycle
        return ProcessLimitSelection(
            controlledProcesses: controlled,
            alwaysRunningProcesses: allIdentities.subtracting(controlled),
            controlledCPUPercent: controlledCPU,
            alwaysRunningCPUPercent: alwaysRunningCPU,
            controlledLimitPercent: controlledLimit,
            targetIsReachable: alwaysRunningCPU + minimumControlledCPU <= requestedLimit
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
