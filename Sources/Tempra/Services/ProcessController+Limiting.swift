import Foundation

// MARK: - CPU limiting

/// The duty-cycle CPU limiter: target selection, the pulse state machine,
/// and the deadline scheduler that drives it between control ticks.
extension ProcessController {
    func scheduledAutomaticResumeInterval(
        for identifier: String,
        processes: Set<ProcessIdentity>
    ) -> TimeInterval {
        if let runtime = limitRuntimes[identifier],
           runtime.processIdentities == processes,
           runtime.scheduledStopDuration > 0 {
            return runtime.scheduledStopDuration
        }
        return ProcessControlMath.limitPeriod
    }

    private func selectLimitTargets(
        for app: ProcessControlTarget,
        limitPercent: Double
    ) -> ProcessLimitSelection {
        let previousControlledProcesses = limitSelections[app.bundleIdentifier]?
            .controlledProcesses ?? []
        let sensitiveProcesses = latencySensitiveProcesses(for: app)
        let criticalProcesses = downloadProtectedProcesses[
            app.bundleIdentifier,
            default: []
        ]
        let offlineSelection = ProcessLimitTargetSelector.select(
            samples: app.processSamples,
            limitPercent: limitPercent,
            previousControlledProcesses: previousControlledProcesses,
            latencySensitiveProcesses: sensitiveProcesses,
            criticalActivityProcesses: criticalProcesses,
            protectsAudio: rules[app.bundleIdentifier]?.protectAudio == true
        )
        guard !offlineSelection.controlledProcesses.isDisjoint(with: sensitiveProcesses) else {
            return offlineSelection
        }
        return ProcessLimitTargetSelector.select(
            samples: app.processSamples,
            limitPercent: limitPercent,
            previousControlledProcesses: previousControlledProcesses,
            latencySensitiveProcesses: sensitiveProcesses,
            criticalActivityProcesses: criticalProcesses,
            protectsAudio: rules[app.bundleIdentifier]?.protectAudio == true
        )
    }

    private func applyLimitPulsePriority(
        to processes: Set<ProcessIdentity>,
        identifier: String
    ) async -> Bool {
        let alreadyApplied = limitPriorityProcesses[identifier, default: []]
        if processes.isSubset(of: alreadyApplied) {
            return true
        }
        limitPulseLoweredProcesses[identifier] = loweredByTempra[
            identifier,
            default: []
        ].intersection(processes)
        let result = await system.applyLimitPriority(processes.subtracting(alreadyApplied))
        limitPriorityProcesses[identifier, default: []].formUnion(result.applied)
        guard workIsCurrent else {
            _ = await restoreLimitPulsePriority(
                for: identifier,
                processes: result.applied
            )
            return false
        }
        guard result.failed.isEmpty else {
            _ = await restoreLimitPulsePriority(
                for: identifier,
                processes: result.applied
            )
            await markUnavailable(
                identifier,
                detail: result.failureDescription
                    ?? "Tempra could not set limiter pulse priority."
            )
            return false
        }
        return true
    }

    func restoreLimitPulsePriority(
        for identifier: String,
        processes: Set<ProcessIdentity>
    ) async -> Bool {
        let appliedProcesses = limitPriorityProcesses[identifier, default: []]
            .intersection(processes)
        guard !appliedProcesses.isEmpty else {
            limitPulseLoweredProcesses.removeValue(forKey: identifier)
            return true
        }
        let lowerPriorityProcesses = (
            limitPulseLoweredProcesses[identifier]
                ?? loweredByTempra[identifier]
                ?? []
        ).intersection(appliedProcesses)
        let normalPriorityProcesses = appliedProcesses.subtracting(lowerPriorityProcesses)
        let lowerResult = lowerPriorityProcesses.isEmpty
            ? ProcessOperationResult()
            : await system.lowerPriority(lowerPriorityProcesses)

        guard workIsCurrent else { return false }
        let normalResult = normalPriorityProcesses.isEmpty
            ? ProcessOperationResult()
            : await system.restorePriority(normalPriorityProcesses)
        guard workIsCurrent else { return false }

        loweredByTempra[identifier, default: []].formUnion(lowerResult.applied)
        loweredByTempra[identifier]?.subtract(
            lowerResult.stale
                .union(normalResult.applied)
                .union(normalResult.stale)
        )
        if loweredByTempra[identifier]?.isEmpty == true {
            loweredByTempra.removeValue(forKey: identifier)
        }

        let failed = lowerResult.failed.union(normalResult.failed)
        let restored = lowerResult.applied.union(lowerResult.stale)
            .union(normalResult.applied)
            .union(normalResult.stale)
        limitPriorityProcesses[identifier]?.subtract(restored)
        if limitPriorityProcesses[identifier]?.isEmpty == true {
            limitPriorityProcesses.removeValue(forKey: identifier)
        }
        if failed.isEmpty {
            limitPulseLoweredProcesses.removeValue(forKey: identifier)
            return true
        }
        limitPulseLoweredProcesses[identifier] = lowerPriorityProcesses.intersection(failed)
        return false
    }

    func runLimitCycle(
        for app: ProcessControlTarget,
        limitPercent requestedLimitPercent: Double
    ) async {
        guard workIsCurrent else { return }
        let identifier = app.bundleIdentifier
        var earlyStopResult: ProcessOperationResult?
        if let runningRuntime = limitRuntimes[identifier],
           runningRuntime.phase == .running,
           runningRuntime.hasActivatedLimit,
           !runningRuntime.processIdentities.isEmpty,
           runningRuntime.processIdentities.allSatisfy({
               !$0.requiresPrivilegedControl
                   && automaticResumeIntervals[$0] != nil
           }) {
            let result = await stopProcesses(
                runningRuntime.processIdentities,
                identifier: identifier,
                reason: .cpuLimitPulse
            )
            guard workIsCurrent else {
                await trackStoppedProcessesFromStaleWork(
                    result.applied,
                    for: identifier
                )
                return
            }
            guard limitControlIsCurrent(
                identifier: identifier,
                generation: runningRuntime.generation,
                processIdentities: runningRuntime.processIdentities
            ) else {
                await resumeProcessesStoppedByObsoleteLimit(
                    result.applied,
                    for: identifier
                )
                return
            }
            guard result.failed.isEmpty else {
                _ = await resumeProcesses(
                    result.applied,
                    identifier: identifier,
                    reason: .stopRollback
                )
                _ = await restoreLimitPulsePriority(
                    for: identifier,
                    processes: runningRuntime.processIdentities
                )
                limitRuntimes.removeValue(forKey: identifier)
                _ = await setStoppedProcesses(
                    stoppedByTempra[identifier, default: []],
                    for: identifier
                )
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not limit every process."
                )
                scheduleNextTick()
                return
            }
            guard !result.applied.isEmpty else {
                _ = await restoreLimitPulsePriority(
                    for: identifier,
                    processes: runningRuntime.processIdentities
                )
                limitRuntimes.removeValue(forKey: identifier)
                _ = await setStoppedProcesses([], for: identifier)
                await setStatus(
                    limitObservationStatus(
                        for: identifier,
                        fallback: requestedLimitPercent
                    ),
                    for: identifier
                )
                return
            }
            guard await setStoppedProcesses(
                result.applied,
                for: identifier
            ) else {
                _ = await restoreLimitPulsePriority(
                    for: identifier,
                    processes: runningRuntime.processIdentities
                )
                limitRuntimes.removeValue(forKey: identifier)
                return
            }
            earlyStopResult = result
        }
        let selection = selectLimitTargets(
            for: app,
            limitPercent: requestedLimitPercent
        )
        limitSelections[identifier] = selection
        let controlledProcesses = selection.controlledProcesses
        await signalTelemetry.recordMeasurement(ProcessLimitMeasurement(
            date: Date(),
            bundleIdentifier: identifier,
            kind: .observation,
            requestedLimitPercent: requestedLimitPercent,
            measuredCPUPercent: selection.controlledCPUPercent,
            cpuDeltaNanoseconds: nil,
            wallDuration: nil,
            deadlineLateness: nil,
            activePulseCount: limitPulseArbiter.activeCount,
            serviceGap: nil
        ))

        let stoppedOutsideSelection = stoppedByTempra[identifier, default: []]
            .subtracting(controlledProcesses)
        if !stoppedOutsideSelection.isEmpty
            || limitRuntimes[identifier]?.processIdentities != controlledProcesses {
            limitPulseArbiter.release(identifier: identifier)
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            guard await resumeStoppedProcesses(
                for: identifier,
                attempts: restorationAttempts
            ) else {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not resume processes removed from the CPU-limit set."
                )
                return
            }
        }

        guard !controlledProcesses.isEmpty else {
            limitPulseArbiter.release(identifier: identifier)
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            await setStatus(
                selection.targetIsReachable
                    ? limitObservationStatus(
                        for: identifier,
                        fallback: requestedLimitPercent
                    )
                    : .waiting,
                for: identifier
            )
            return
        }

        let limitPercent = selection.controlledLimitPercent
        let now = clock.now()
        guard let nowCPU = await readCPUTime(
            for: controlledProcesses,
            identifier: identifier
        ) else { return }

        if limitRuntimes[identifier] == nil {
            let initialUsage = ProcessControlMath.normalizedCPUPercent(
                selection.controlledCPUPercent
            )
            let startsAboveLimit = initialUsage > limitPercent
            let runtime = LimitRuntime(
                lastCPUNanoseconds: nowCPU,
                lastAccountingAt: now,
                runStartedAt: nil,
                estimatedFullSpeedCPU: max(initialUsage, limitPercent, 1),
                lastMeasuredCPUPercent: initialUsage,
                dutyFactor: 0,
                hasActivatedLimit: startsAboveLimit,
                scheduledStopDuration: 0,
                stoppedAt: nil,
                generation: 1,
                phase: startsAboveLimit ? .running : .observing,
                processIdentities: controlledProcesses
            )
            limitRuntimes[identifier] = runtime
            scheduleLimitObservation(
                for: identifier,
                runtime: runtime,
                limitPercent: limitPercent,
                now: now,
                after: 0.001
            )
            await setStatus(
                startsAboveLimit
                    ? limitStatus(for: identifier, fallback: requestedLimitPercent)
                    : limitObservationStatus(
                        for: identifier,
                        fallback: requestedLimitPercent
                    ),
                for: identifier
            )
            return
        }

        if var stoppedRuntime = limitRuntimes[identifier],
           stoppedRuntime.phase == .stopped {
            let guardianControlsPulse = crashWatchdog.controlsLimitPulseCadence
                && stoppedRuntime.processIdentities.allSatisfy {
                    !$0.requiresPrivilegedControl
                        && automaticResumeIntervals[$0] != nil
                }
            let resumed: Bool
            if guardianControlsPulse {
                resumed = true
            } else {
                resumed = await resumeStoppedProcesses(
                    for: identifier,
                    attempts: restorationAttempts,
                    reason: .cpuLimitPulse,
                    retainingAutomaticResume: stoppedRuntime.processIdentities,
                    retainingLimitPriority: true
                )
            }
            guard workIsCurrent else { return }
            guard resumed else {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not finish the CPU-limit pulse."
                )
                return
            }

            let period = ProcessControlMath.controlPeriod(
                usage: stoppedRuntime.lastMeasuredCPUPercent ?? 0,
                previousDutyFactor: stoppedRuntime.dutyFactor
            )
            let elapsed = max(
                0,
                ProcessControlMath.timeInterval(
                    stoppedRuntime.lastAccountingAt.duration(to: clock.now())
                )
            )
            stoppedRuntime.phase = .running
            stoppedRuntime.runStartedAt = clock.now()
            stoppedRuntime.stoppedAt = nil
            limitRuntimes[identifier] = stoppedRuntime
            scheduleLimitObservation(
                for: identifier,
                runtime: stoppedRuntime,
                limitPercent: limitPercent,
                now: clock.now(),
                after: max(0.001, period - elapsed)
            )
            await setStatus(
                limitStatus(for: identifier, fallback: requestedLimitPercent),
                for: identifier
            )
            return
        }

        let existingRuntime = limitRuntimes[identifier]
        var runtime = LimitRuntime.advancing(
            existingRuntime,
            to: now,
            cpuNanoseconds: nowCPU,
            sampledCPUPercent: selection.controlledCPUPercent,
            limitPercent: limitPercent,
            processIdentities: controlledProcesses
        )
        let usage = runtime.lastMeasuredCPUPercent ?? 0
        let dutyFactor = runtime.dutyFactor
        let generation = runtime.generation
        let controlPeriod = ProcessControlMath.controlPeriod(
            usage: usage,
            previousDutyFactor: existingRuntime?.dutyFactor ?? 0
        )
        limitRuntimes[identifier] = runtime
        limitDeadlines.remove(identifier: identifier)

        await signalTelemetry.recordMeasurement(ProcessLimitMeasurement(
            date: Date(),
            bundleIdentifier: identifier,
            kind: .pulse,
            requestedLimitPercent: limitPercent,
            measuredCPUPercent: usage,
            cpuDeltaNanoseconds: existingRuntime.flatMap {
                nowCPU >= $0.lastCPUNanoseconds ? nowCPU - $0.lastCPUNanoseconds : nil
            },
            wallDuration: existingRuntime.map {
                max(0, ProcessControlMath.timeInterval($0.lastAccountingAt.duration(to: now)))
            },
            deadlineLateness: nil,
            activePulseCount: limitPulseArbiter.activeCount,
            serviceGap: nil
        ))

        guard dutyFactor >= ProcessControlMath.minimumDutyFactor else {
            let priorityRestored = await restoreLimitPulsePriority(
                for: identifier,
                processes: controlledProcesses
            )
            let resumeResult: ProcessOperationResult
            let synchronized: Bool
            if earlyStopResult != nil {
                resumeResult = await resumeProcesses(
                    controlledProcesses,
                    identifier: identifier,
                    reason: .cpuLimitPulse
                )
                synchronized = await setStoppedProcesses(
                    resumeResult.failed,
                    for: identifier
                )
            } else {
                resumeResult = await system.resume(controlledProcesses)
                synchronized = true
            }
            guard workIsCurrent else { return }
            guard priorityRestored,
                  synchronized,
                  resumeResult.failed.isEmpty else {
                await markUnavailable(
                    identifier,
                    detail: resumeResult.failureDescription
                        ?? "Tempra could not keep the CPU-limited process running."
                )
                return
            }
            scheduleLimitObservation(
                for: identifier,
                runtime: runtime,
                limitPercent: limitPercent,
                now: now,
                after: controlPeriod
            )
            await setStatus(
                limitObservationStatus(
                    for: identifier,
                    fallback: requestedLimitPercent
                ),
                for: identifier
            )
            return
        }

        guard await prepareLimitStop(
            controlledProcesses,
            identifier: identifier,
            generation: generation,
            requestedLimitPercent: requestedLimitPercent
        ) else {
            scheduleLimitScheduler()
            return
        }
        guard await prepareWatchdogToStop(controlledProcesses, for: identifier) else {
            limitRuntimes.removeValue(forKey: identifier)
            scheduleNextTick()
            return
        }
        guard let automaticResumeChange = await armWatchdogAutomaticResume(
            controlledProcesses,
            for: identifier,
            automaticResumeAfter: dutyFactor
        ) else {
            scheduleNextTick()
            return
        }
        guard limitControlIsCurrent(
            identifier: identifier,
            generation: generation,
            processIdentities: controlledProcesses
        ) else {
            await cancelWatchdogAutomaticResume(
                automaticResumeChange,
                for: identifier
            )
            return
        }
        guard await applyLimitPulsePriority(
            to: controlledProcesses,
            identifier: identifier
        ) else {
            await cancelWatchdogAutomaticResume(
                automaticResumeChange,
                for: identifier
            )
            limitRuntimes.removeValue(forKey: identifier)
            scheduleNextTick()
            return
        }

        let result: ProcessOperationResult
        if let earlyStopResult {
            result = earlyStopResult
        } else {
            result = await stopProcesses(
                controlledProcesses,
                identifier: identifier,
                reason: .cpuLimitPulse
            )
        }
        guard workIsCurrent else {
            await trackStoppedProcessesFromStaleWork(result.applied, for: identifier)
            return
        }
        guard limitControlIsCurrent(
            identifier: identifier,
            generation: generation,
            processIdentities: controlledProcesses
        ) else {
            await resumeProcessesStoppedByObsoleteLimit(result.applied, for: identifier)
            _ = await restoreLimitPulsePriority(
                for: identifier,
                processes: controlledProcesses
            )
            return
        }
        guard result.failed.isEmpty else {
            _ = await resumeProcesses(
                result.applied,
                identifier: identifier,
                reason: .stopRollback
            )
            _ = await restoreLimitPulsePriority(
                for: identifier,
                processes: controlledProcesses
            )
            limitRuntimes.removeValue(forKey: identifier)
            _ = await setStoppedProcesses(
                stoppedByTempra[identifier, default: []],
                for: identifier
            )
            await markUnavailable(identifier, detail: "Tempra could not limit every process.")
            scheduleNextTick()
            return
        }
        guard !result.applied.isEmpty else {
            _ = await restoreLimitPulsePriority(
                for: identifier,
                processes: controlledProcesses
            )
            limitRuntimes.removeValue(forKey: identifier)
            _ = await setStoppedProcesses([], for: identifier)
            await setStatus(
                limitObservationStatus(
                    for: identifier,
                    fallback: requestedLimitPercent
                ),
                for: identifier
            )
            return
        }
        guard await setStoppedProcesses(result.applied, for: identifier) else {
            _ = await restoreLimitPulsePriority(
                for: identifier,
                processes: controlledProcesses
            )
            limitRuntimes.removeValue(forKey: identifier)
            return
        }

        let stoppedAt = clock.now()
        runtime.phase = .stopped
        runtime.runStartedAt = nil
        runtime.stoppedAt = stoppedAt
        limitRuntimes[identifier] = runtime
        scheduleLimitObservation(
            for: identifier,
            runtime: runtime,
            limitPercent: limitPercent,
            now: stoppedAt,
            after: dutyFactor
        )
        await setStatus(
            limitStatus(for: identifier, fallback: requestedLimitPercent),
            for: identifier
        )
        await updatePauseWakeMonitoring()
    }

    private func scheduleLimitObservation(
        for identifier: String,
        runtime: LimitRuntime,
        limitPercent: Double,
        now: ContinuousClock.Instant,
        after interval: TimeInterval
    ) {
        limitDeadlines.upsert(LimitDeadline(
            identifier: identifier,
            deadline: now.advanced(by: ProcessControlMath.duration(max(0.001, interval))),
            generation: runtime.generation,
            limitPercent: limitPercent,
            processIdentities: runtime.processIdentities
        ))
    }

    private func prepareLimitStop(
        _ processes: Set<ProcessIdentity>,
        identifier: String,
        generation: UInt64,
        requestedLimitPercent: Double
    ) async -> Bool {
        var activeDownloadProcesses: Set<ProcessIdentity> = []
        var inactiveDownloadProcesses: Set<ProcessIdentity> = []

        for process in processes.sorted(by: { $0.pid < $1.pid }) {
            let fileActivity = await criticalFileActivity(for: process)
            guard workIsCurrent,
                  limitControlIsCurrent(
                    identifier: identifier,
                    generation: generation,
                    processIdentities: processes
                  ) else {
                return false
            }
            switch fileActivity {
            case .activeDownload:
                activeDownloadProcesses.insert(process)
            case .inactive:
                inactiveDownloadProcesses.insert(process)
            case .unknown:
                break
            }
        }

        if !inactiveDownloadProcesses.isEmpty {
            downloadProtectedProcesses[identifier]?.subtract(inactiveDownloadProcesses)
            if downloadProtectedProcesses[identifier]?.isEmpty == true {
                downloadProtectedProcesses.removeValue(forKey: identifier)
            }
        }

        guard !activeDownloadProcesses.isEmpty else {
            return true
        }

        downloadProtectedProcesses[identifier, default: []].formUnion(
            activeDownloadProcesses
        )

        guard workIsCurrent,
              let app = groups[identifier],
              rules[identifier]?.action == .limit else {
            return false
        }

        let revisedSelection = selectLimitTargets(
            for: app,
            limitPercent: requestedLimitPercent
        )
        limitSelections[identifier] = revisedSelection
        if revisedSelection.controlledProcesses != processes {
            if !activeDownloadProcesses.isEmpty {
                await recordPreventedStop(
                    activeDownloadProcesses,
                    identifier: identifier,
                    reason: .criticalFileActivity
                )
            }
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            await runLimitCycle(for: app, limitPercent: requestedLimitPercent)
            return false
        }
        return true
    }

    func maintainLimitCycle(
        for app: ProcessControlTarget,
        limitPercent requestedLimitPercent: Double
    ) async {
        guard workIsCurrent else { return }
        let identifier = app.bundleIdentifier
        let selection = selectLimitTargets(
            for: app,
            limitPercent: requestedLimitPercent
        )
        limitSelections[identifier] = selection
        guard let runtime = limitRuntimes[identifier] else {
            await runLimitCycle(for: app, limitPercent: requestedLimitPercent)
            return
        }

        if runtime.processIdentities != selection.controlledProcesses {
            limitPulseArbiter.release(identifier: identifier)
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            await runLimitCycle(for: app, limitPercent: requestedLimitPercent)
            return
        }

        await setStatus(
            runtime.phase == .observing
                ? limitObservationStatus(
                    for: identifier,
                    fallback: requestedLimitPercent
                )
                : limitStatus(for: identifier, fallback: requestedLimitPercent),
            for: identifier
        )
    }

    private func limitControlIsCurrent(
        identifier: String,
        generation: UInt64,
        processIdentities: Set<ProcessIdentity>
    ) -> Bool {
        guard managementIsActive,
              rules[identifier]?.action == .limit,
              groups[identifier]?.processIdentities.isSuperset(of: processIdentities) == true,
              let runtime = limitRuntimes[identifier],
              runtime.generation == generation,
              runtime.processIdentities == processIdentities else {
            return false
        }
        if let minimumRevision = foregroundActivationMinimumRevision[identifier],
           revision < minimumRevision {
            return false
        }
        if let protectionUntil = foregroundActivationProtectionUntil[identifier],
           clock.now() < protectionUntil {
            return false
        }
        return true
    }

    private func resumeProcessesStoppedByObsoleteLimit(
        _ processes: Set<ProcessIdentity>,
        for identifier: String
    ) async {
        guard !processes.isEmpty else { return }
        let result = await resumeProcesses(
            processes,
            identifier: identifier,
            reason: .obsoleteLimit
        )
        let remaining = stoppedByTempra[identifier, default: []]
            .subtracting(result.applied.union(result.stale))
            .union(result.failed)
        let synchronized = await setStoppedProcesses(remaining, for: identifier)
        if !result.failed.isEmpty || !synchronized {
            await markUnavailable(
                identifier,
                detail: "Tempra could not resume a process after canceling an obsolete CPU-limit pulse."
            )
        }
    }

    private func limitStatus(
        for identifier: String,
        fallback: Double
    ) -> ManagementStatus {
        let requestedLimit = rules[identifier]?.limitPercent ?? fallback
        if limitSelections[identifier]?.targetIsReachable == false {
            return .limitedWithProtectedProcesses(requestedLimit)
        }
        return .limited(requestedLimit)
    }

    private func limitObservationStatus(
        for identifier: String,
        fallback: Double
    ) -> ManagementStatus {
        if limitRuntimes[identifier]?.hasActivatedLimit == true {
            return limitStatus(for: identifier, fallback: fallback)
        }
        if rules[identifier]?.usesLowerCPUPriority == true,
           loweredByTempra[identifier]?.isEmpty == false {
            return .lowerPriority
        }
        return .normal
    }

    func scheduleLimitScheduler() {
        guard managementIsActive, let nextDeadline = limitDeadlines.first else {
            limitSchedulerTask?.cancel()
            limitSchedulerTask = nil
            scheduledLimitDeadline = nil
            limitSchedulerGeneration = ProcessControlMath.nextGeneration(
                after: limitSchedulerGeneration
            )
            return
        }

        if limitSchedulerTask != nil,
           scheduledLimitDeadline == nextDeadline.deadline {
            return
        }

        limitSchedulerTask?.cancel()
        limitSchedulerGeneration = ProcessControlMath.nextGeneration(
            after: limitSchedulerGeneration
        )
        let schedulerGeneration = limitSchedulerGeneration
        let deadline = nextDeadline.deadline
        scheduledLimitDeadline = deadline
        let wakeRegistration = ProcessControlWakeRegistration()
        limitSchedulerTask = Task(priority: .high) { [weak self, clock] in
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    wakeRegistration.install(clock.scheduleWake(deadline) {
                        continuation.resume()
                    })
                }
            } onCancel: {
                wakeRegistration.cancel()
            }
            guard !Task.isCancelled else { return }
            await self?.requestLimitDeadlineProcessing(
                schedulerGeneration: schedulerGeneration
            )
        }
    }

    func processLimitDeadlines(
        schedulerGeneration: UInt64
    ) async {
        guard schedulerGeneration == limitSchedulerGeneration else { return }
        let now = clock.now()
        var dueDeadlines: [LimitDeadline] = []
        while let nextDeadline = limitDeadlines.first,
              nextDeadline.deadline <= now,
              let deadline = limitDeadlines.popFirst() {
            dueDeadlines.append(deadline)
        }

        for deadline in dueDeadlines {
            guard workIsCurrent else { return }
            let deadlineLateness = max(
                0,
                ProcessControlMath.timeInterval(deadline.deadline.duration(to: clock.now()))
            )
            await signalTelemetry.recordMeasurement(ProcessLimitMeasurement(
                date: Date(),
                bundleIdentifier: deadline.identifier,
                kind: .deadline,
                requestedLimitPercent: deadline.limitPercent,
                measuredCPUPercent: nil,
                cpuDeltaNanoseconds: nil,
                wallDuration: nil,
                deadlineLateness: deadlineLateness,
                activePulseCount: limitPulseArbiter.activeCount,
                serviceGap: nil
            ))
            await evaluateLimitDeadline(deadline)
            guard workIsCurrent else { return }
        }

        guard schedulerGeneration == limitSchedulerGeneration else {
            scheduleLimitScheduler()
            return
        }
        limitSchedulerTask = nil
        scheduledLimitDeadline = nil
        scheduleLimitScheduler()
    }

    func resetLimitScheduler() {
        limitSchedulerTask?.cancel()
        limitSchedulerTask = nil
        scheduledLimitDeadline = nil
        pendingLimitSchedulerGeneration = nil
        limitSchedulerGeneration = ProcessControlMath.nextGeneration(
            after: limitSchedulerGeneration
        )
        limitDeadlines.removeAll()
        limitPulseArbiter.removeAll()
    }

    private func evaluateLimitDeadline(_ deadline: LimitDeadline) async {
        guard workIsCurrent,
              managementIsActive,
              let runtime = limitRuntimes[deadline.identifier],
              runtime.generation == deadline.generation,
              runtime.processIdentities == deadline.processIdentities,
              let rule = rules[deadline.identifier],
              rule.action == .limit,
              let app = groups[deadline.identifier],
              deadline.processIdentities.isSubset(of: app.processIdentities) else {
            return
        }

        let appIsFrontmost = await isFrontmost(app)
        guard workIsCurrent else { return }
        if appIsFrontmost {
            if await restore(
                identifier: deadline.identifier,
                resetDelay: true,
                attempts: restorationAttempts
            ) {
                await setStatus(.normal, for: deadline.identifier)
            } else {
                await markUnavailable(
                    deadline.identifier,
                    detail: "Tempra could not restore every process."
                )
            }
            scheduleNextTick()
            return
        }

        await runLimitCycle(for: app, limitPercent: rule.limitPercent)
    }
}
