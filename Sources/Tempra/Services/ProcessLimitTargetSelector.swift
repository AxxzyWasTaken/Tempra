import Foundation

/// The resource a limit selection reasons about.
///
/// CPU demand is percent that sums across cores, so it runs from 0 to
/// `cores * 100`. GPU demand is watts, because GPU power is what a GPU limit
/// caps and it is not proportional to busy time. A selection only ever compares
/// values of one demand against a limit expressed in the same unit.
enum ProcessLimitDemand: Sendable {
    case cpu
    case gpu
}

extension ManagedProcessSample {
    func demandPercent(_ demand: ProcessLimitDemand) -> Double {
        switch demand {
        case .cpu:
            cpuPercent
        case .gpu:
            gpuWatts
        }
    }
}

struct ProcessLimitSelection: Equatable, Sendable {
    let controlledProcesses: Set<ProcessIdentity>
    let alwaysRunningProcesses: Set<ProcessIdentity>
    /// Measured usage of the controlled processes, in `demand`'s unit:
    /// CPU percent for `.cpu`, watts for `.gpu`.
    let controlledDemand: Double
    /// Measured usage of the processes that keep running, in `demand`'s unit.
    let alwaysRunningDemand: Double
    /// The limit the controlled subset must hold, in `demand`'s unit.
    let controlledLimit: Double
    let targetIsReachable: Bool
    let protectionReasons: [ProcessIdentity: Set<ProcessProtectionReason>]
    /// The resource — and therefore the unit — every value above reasons in.
    var demand: ProcessLimitDemand = .cpu

    static let empty = ProcessLimitSelection(
        controlledProcesses: [],
        alwaysRunningProcesses: [],
        controlledDemand: 0,
        alwaysRunningDemand: 0,
        controlledLimit: 0,
        targetIsReachable: true,
        protectionReasons: [:]
    )
}

enum ProcessLimitTargetSelector {
    static func select(
        samples: [ManagedProcessSample],
        limitPercent: Double,
        demand: ProcessLimitDemand = .cpu,
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

        var protectionReasons: [ProcessIdentity: Set<ProcessProtectionReason>] = [:]
        for sample in normalizedSamples {
            if !sample.hasCPUMeasurement {
                protectionReasons[sample.identity, default: []].insert(
                    .missingCPUMeasurement
                )
            }
            if protectsAudio, sample.isPlayingAudio {
                protectionReasons[sample.identity, default: []].insert(.audioPlayback)
            }
            if criticalActivityProcesses.contains(sample.identity) {
                protectionReasons[sample.identity, default: []].insert(
                    .criticalFileActivity
                )
            }
            if sample.networkActivity.isLatencySensitive
                || latencySensitiveProcesses.contains(sample.identity) {
                protectionReasons[sample.identity, default: []].insert(.networkActivity)
            }
        }

        let hardProtectedProcesses = Set(normalizedSamples.compactMap { sample in
            (normalizedSamples.count > 1 && !sample.hasCPUMeasurement)
                || (protectsAudio && sample.isPlayingAudio)
                ? sample.identity
                : nil
        })
        var softProtectedProcesses = Set(normalizedSamples.compactMap { sample in
            sample.networkActivity.isLatencySensitive ? sample.identity : nil
        })
        softProtectedProcesses.formUnion(
            latencySensitiveProcesses.intersection(samplesByIdentity.keys)
        )
        softProtectedProcesses.formUnion(
            criticalActivityProcesses.intersection(samplesByIdentity.keys)
        )

        if normalizedSamples.count > 1 {
            let lifelineOrder = { (first: ManagedProcessSample, second: ManagedProcessSample) in
                sampleOrderByDemandThenIdentity(first, second, demand: demand)
            }
            let mainLifeline = normalizedSamples
                .filter(\.isMainProcess)
                .min(by: lifelineOrder)
                ?? normalizedSamples.min(by: lifelineOrder)
            if let mainLifeline {
                softProtectedProcesses.insert(mainLifeline.identity)
                protectionReasons[mainLifeline.identity, default: []].insert(
                    .mainProcessLifeline
                )
            }
        }

        let totalCPU = normalizedSamples.reduce(0) { $0 + $1.demandPercent(demand) }
        let activationThreshold = ProcessControlMath.activationThreshold(for: requestedLimit)
        guard normalizedSamples.count == 1
                || !previousControlledProcesses.isEmpty
                || totalCPU > activationThreshold else {
            return makeSelection(
                controlled: [],
                samples: normalizedSamples,
                requestedLimit: requestedLimit,
                demand: demand,
                minimumControlledDutyCycle: normalizedMinimumDutyCycle,
                protectionReasons: protectionReasons
            )
        }

        let eligible = normalizedSamples.filter {
            !hardProtectedProcesses.contains($0.identity)
                && ($0.demandPercent(demand) > 0
                    || previousControlledProcesses.contains($0.identity))
        }
        guard !eligible.isEmpty else {
            return makeSelection(
                controlled: [],
                samples: normalizedSamples,
                requestedLimit: requestedLimit,
                demand: demand,
                minimumControlledDutyCycle: normalizedMinimumDutyCycle,
                protectionReasons: protectionReasons
            )
        }

        if normalizedSamples.count == 1, let onlyProcess = eligible.first {
            return makeSelection(
                controlled: [onlyProcess.identity],
                samples: normalizedSamples,
                requestedLimit: requestedLimit,
                demand: demand,
                minimumControlledDutyCycle: normalizedMinimumDutyCycle,
                protectionReasons: protectionReasons
            )
        }

        let hardProtectedCPU = normalizedSamples.reduce(0) { result, sample in
            result + (hardProtectedProcesses.contains(sample.identity)
                ? sample.demandPercent(demand)
                : 0)
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
            demand: demand,
            stopThreshold: selectionThreshold,
            previousControlledProcesses: previousControlledProcesses,
            softProtectedProcesses: softProtectedProcesses
        )
        let preferredControlledCPU = normalizedSamples.reduce(0) { result, sample in
            result + (preferredControlled.contains(sample.identity)
                ? sample.demandPercent(demand)
                : 0)
        }
        let previousEligibleProcesses = previousControlledProcesses.intersection(
            eligible.map(\.identity)
        )
        if totalCPU - preferredControlledCPU <= selectionThreshold,
           !preferredControlled.isEmpty || previousEligibleProcesses.isEmpty {
            return makeSelection(
                controlled: preferredControlled,
                samples: normalizedSamples,
                requestedLimit: requestedLimit,
                demand: demand,
                minimumControlledDutyCycle: normalizedMinimumDutyCycle,
                protectionReasons: protectionReasons
            )
        }

        let controlled = selectCandidates(
            eligible,
            totalCPU: totalCPU,
            demand: demand,
            stopThreshold: selectionThreshold,
            previousControlledProcesses: previousControlledProcesses,
            softProtectedProcesses: softProtectedProcesses
        )

        return makeSelection(
            controlled: controlled,
            samples: normalizedSamples,
            requestedLimit: requestedLimit,
            demand: demand,
            minimumControlledDutyCycle: normalizedMinimumDutyCycle,
            protectionReasons: protectionReasons
        )
    }

    private static func selectCandidates(
        _ candidates: [ManagedProcessSample],
        totalCPU: Double,
        demand: ProcessLimitDemand,
        stopThreshold: Double,
        previousControlledProcesses: Set<ProcessIdentity>,
        softProtectedProcesses: Set<ProcessIdentity>
    ) -> Set<ProcessIdentity> {
        let candidateIdentities = Set(candidates.map(\.identity))
        let previousEligible = previousControlledProcesses.intersection(candidateIdentities)
        if !previousEligible.isEmpty {
            let previousControlledCPU = candidates.reduce(0) { result, sample in
                result + (previousEligible.contains(sample.identity)
                    ? sample.demandPercent(demand)
                    : 0)
            }
            if totalCPU - previousControlledCPU <= stopThreshold {
                return previousEligible
            }
        }

        let orderedCandidates = candidates.sorted { first, second in
            if first.demandPercent(demand) != second.demandPercent(demand) {
                return first.demandPercent(demand) > second.demandPercent(demand)
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
            controlledCPU += sample.demandPercent(demand)
        }
        return controlled
    }

    private static func makeSelection(
        controlled: Set<ProcessIdentity>,
        samples: [ManagedProcessSample],
        requestedLimit: Double,
        demand: ProcessLimitDemand,
        minimumControlledDutyCycle: Double,
        protectionReasons: [ProcessIdentity: Set<ProcessProtectionReason>]
    ) -> ProcessLimitSelection {
        let controlledCPU = samples.reduce(0) { result, sample in
            result + (controlled.contains(sample.identity)
                ? sample.demandPercent(demand)
                : 0)
        }
        let totalCPU = samples.reduce(0) { $0 + $1.demandPercent(demand) }
        let alwaysRunningCPU = max(0, totalCPU - controlledCPU)
        let allIdentities = Set(samples.map(\.identity))
        let alwaysRunningProcesses = allIdentities.subtracting(controlled)
        let retainedProtectionReasons = protectionReasons.filter { identity, reasons in
            alwaysRunningProcesses.contains(identity) && !reasons.isEmpty
        }
        let controlledLimit = controlled.isEmpty
            ? 0
            : max(0, requestedLimit - alwaysRunningCPU)
        let minimumControlledCPU = controlledCPU * minimumControlledDutyCycle
        return ProcessLimitSelection(
            controlledProcesses: controlled,
            alwaysRunningProcesses: alwaysRunningProcesses,
            controlledDemand: controlledCPU,
            alwaysRunningDemand: alwaysRunningCPU,
            controlledLimit: controlledLimit,
            targetIsReachable: alwaysRunningCPU + minimumControlledCPU <= requestedLimit,
            protectionReasons: retainedProtectionReasons,
            demand: demand
        )
    }

    private static func sampleOrderByDemandThenIdentity(
        _ first: ManagedProcessSample,
        _ second: ManagedProcessSample,
        demand: ProcessLimitDemand
    ) -> Bool {
        if first.demandPercent(demand) != second.demandPercent(demand) {
            return first.demandPercent(demand) < second.demandPercent(demand)
        }
        return first.identity.pid < second.identity.pid
    }
}
