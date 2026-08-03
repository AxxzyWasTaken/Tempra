import AppKit
import Foundation

actor ProcessController {
    typealias EventHandler = @MainActor @Sendable (ProcessControllerEvent) -> Void
    typealias FrontmostProvider = @MainActor @Sendable () -> String?
    typealias ApplicationAction = @MainActor @Sendable (String) -> Bool
    typealias WindowSnapshotProvider = @Sendable () -> WindowVisibilitySnapshot?

    @TaskLocal private static var reconciliationContext: ProcessReconciliationContext?

    private typealias LimitPhase = ProcessLimitSchedulerModel.Phase
    private typealias LimitRuntime = ProcessLimitSchedulerModel.Runtime
    private typealias LimitDeadline = ProcessLimitSchedulerModel.Deadline
    private typealias LimitDeadlineQueue = ProcessLimitSchedulerModel.DeadlineQueue

    private let system: any ProcessSystemControlling
    private let crashWatchdog: any ProcessCrashWatchdogControlling
    private let frontmostProvider: FrontmostProvider
    private let activateApplication: ApplicationAction
    private let hideApplication: ApplicationAction
    private let forceTerminateApplication: ApplicationAction
    private let windowSnapshotProvider: WindowSnapshotProvider
    private let controlInterval: TimeInterval
    private let minimumRunDuration: TimeInterval
    private let clock: ProcessControlClock
    private let failureRetryInterval: TimeInterval = 1
    private let maximumLimitStopDuration: TimeInterval = 0.75
    private let runningLimitRecheckInterval: TimeInterval = 1
    private let limitObservationInterval: TimeInterval = 1
    private let minimumDemandSampleDuration: TimeInterval = 0.25
    private let userActivationProbeDuration: TimeInterval = 0.4
    private let audioProtectionReleaseDelay: TimeInterval = 15
    private let restorationAttempts = 3
    private let visibilityRecheckInterval: TimeInterval = 1
    static let launchGracePeriod: TimeInterval = 60

    private var eventHandler: EventHandler?
    private var groups: [String: ProcessControlTarget] = [:]
    private var rules: [String: AppRule] = [:]
    private var backgroundSince: [String: Date] = [:]
    private var stoppedByTempra: [String: Set<ProcessIdentity>] = [:]
    private var backgroundedByTempra: [String: Set<ProcessIdentity>] = [:]
    private var limitRuntimes: [String: LimitRuntime] = [:]
    private var pausedBaselineCPU: [String: Double] = [:]
    private var pauseActivationProbeUntil: [String: Date] = [:]
    private var audioProtection = AudioProtectionTracker()
    private var hideRequested: Set<String> = []
    private var quitRequested: Set<String> = []
    private var statuses: [String: ManagementStatus] = [:]
    private var isEnabled = true
    private var revision: UInt64 = 0
    private var stateID = UUID()
    private var isDrainingReconciliationQueue = false
    private var needsStateReconciliation = false
    private var needsCadenceTick = false
    private var pendingLimitSchedulerGeneration: UInt64?
    private var reconciliationWaiters: [CheckedContinuation<Void, Never>] = []
    private var tickTask: Task<Void, Never>?
    private var limitDeadlines = LimitDeadlineQueue()
    private var limitSchedulerTask: Task<Void, Never>?
    private var scheduledLimitDeadline: ContinuousClock.Instant?
    private var limitSchedulerGeneration: UInt64 = 0
    private var scheduledTickInterval: TimeInterval?
    private var scheduledTickDeadline: ContinuousClock.Instant?
    private var isPauseWakeMonitoringEnabled = false

    init(
        system: any ProcessSystemControlling = RoutedProcessSystemController(),
        crashWatchdog: any ProcessCrashWatchdogControlling = ProcessCrashWatchdog(),
        frontmostProvider: @escaping FrontmostProvider = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        activateApplication: @escaping ApplicationAction = { identifier in
            NSRunningApplication
                .runningApplications(withBundleIdentifier: identifier)
                .map {
                    $0.activate(
                        from: NSRunningApplication.current,
                        options: [.activateAllWindows]
                    )
                }
                .contains(true)
        },
        hideApplication: @escaping ApplicationAction = { identifier in
            NSRunningApplication
                .runningApplications(withBundleIdentifier: identifier)
                .map { $0.hide() }
                .contains(true)
        },
        terminateApplication: @escaping ApplicationAction = { identifier in
            NSRunningApplication
                .runningApplications(withBundleIdentifier: identifier)
                .map { $0.forceTerminate() }
                .contains(true)
        },
        windowSnapshotProvider: @escaping WindowSnapshotProvider = {
            WindowVisibilitySnapshot.capture()
        },
        controlInterval: TimeInterval = 0.5,
        minimumRunDuration: TimeInterval = 0.025,
        clock: ProcessControlClock = .continuous
    ) {
        self.system = system
        self.crashWatchdog = crashWatchdog
        self.frontmostProvider = frontmostProvider
        self.activateApplication = activateApplication
        self.hideApplication = hideApplication
        self.forceTerminateApplication = terminateApplication
        self.windowSnapshotProvider = windowSnapshotProvider
        self.controlInterval = controlInterval
        self.minimumRunDuration = minimumRunDuration
        self.clock = clock
    }

    func setEventHandler(_ handler: @escaping EventHandler) {
        eventHandler = handler
    }

    func update(
        targets: [ProcessControlTarget],
        rules: [String: AppRule],
        isEnabled: Bool,
        revision: UInt64
    ) async -> ProcessControlSnapshot {
        guard revision >= self.revision else { return snapshot() }
        let previousRules = self.rules
        self.revision = revision
        stateID = UUID()
        groups = Dictionary(uniqueKeysWithValues: targets.map { ($0.bundleIdentifier, $0) })
        self.rules = rules.reduce(into: [:]) { result, entry in
            guard groups[entry.key]?.isProtectedAudioInfrastructure != true else { return }
            result[entry.key] = SystemProcessRulePolicy.normalized(entry.value)
        }
        self.isEnabled = isEnabled

        let changedRuleIdentifiers = Set(previousRules.keys).union(self.rules.keys).filter {
            previousRules[$0] != self.rules[$0]
        }
        for identifier in changedRuleIdentifiers {
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
        }

        needsStateReconciliation = true
        await drainReconciliationQueue()
        return snapshot()
    }

    private func drainReconciliationQueue() async {
        if isDrainingReconciliationQueue {
            await withCheckedContinuation { continuation in
                reconciliationWaiters.append(continuation)
            }
            return
        }

        isDrainingReconciliationQueue = true
        while needsStateReconciliation || needsCadenceTick
                || pendingLimitSchedulerGeneration != nil {
            if needsStateReconciliation {
                needsStateReconciliation = false
                let context = ProcessReconciliationContext(stateID: stateID, revision: revision)
                await Self.$reconciliationContext.withValue(context) {
                    await performStateReconciliation()
                }
                continue
            }

            if let schedulerGeneration = pendingLimitSchedulerGeneration {
                pendingLimitSchedulerGeneration = nil
                let context = ProcessReconciliationContext(stateID: stateID, revision: revision)
                await Self.$reconciliationContext.withValue(context) {
                    await processLimitDeadlines(schedulerGeneration: schedulerGeneration)
                }
                continue
            }

            needsCadenceTick = false
            let context = ProcessReconciliationContext(stateID: stateID, revision: revision)
            await Self.$reconciliationContext.withValue(context) {
                await tick(trigger: .cadence)
            }
        }
        isDrainingReconciliationQueue = false

        let waiters = reconciliationWaiters
        reconciliationWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    private func performStateReconciliation() async {
        await reconcileControlledProcesses()
        guard workIsCurrent else { return }

        let targetIdentifiers = Set(groups.keys)
        audioProtection.retain { identifier in
            targetIdentifiers.contains(identifier)
                && self.rules[identifier]?.hasBehavior == true
                && self.rules[identifier]?.protectAudio == true
        }
        let identifiersToRestore = trackedIdentifiers.filter {
            !targetIdentifiers.contains($0) || self.rules[$0]?.hasBehavior != true
        }
        for identifier in identifiersToRestore {
            let restored = await restore(
                identifier: identifier,
                resetDelay: true,
                attempts: restorationAttempts
            )
            guard workIsCurrent else { return }
            if restored {
                await setStatus(.normal, for: identifier)
                statuses.removeValue(forKey: identifier)
            } else {
                await markUnavailable(identifier, detail: "Tempra could not restore every process.")
            }
        }

        guard workIsCurrent else { return }
        if isEnabled {
            await tick(trigger: .stateUpdate)
        } else {
            _ = await restoreAll(attempts: 3)
        }
    }

    private func requestCadenceTick() async {
        needsCadenceTick = true
        await drainReconciliationQueue()
    }

    private func requestLimitDeadlineProcessing(schedulerGeneration: UInt64) async {
        guard schedulerGeneration == limitSchedulerGeneration else { return }
        pendingLimitSchedulerGeneration = schedulerGeneration
        await drainReconciliationQueue()
    }

    private var workIsCurrent: Bool {
        guard let context = Self.reconciliationContext else { return true }
        return context.stateID == stateID
    }

    private var eventRevision: UInt64 {
        Self.reconciliationContext?.revision ?? revision
    }

    func restore(bundleIdentifier: String) async -> ProcessControlSnapshot {
        if await restore(identifier: bundleIdentifier, resetDelay: true, attempts: 3) {
            await setStatus(.normal, for: bundleIdentifier)
        } else {
            await markUnavailable(
                bundleIdentifier,
                detail: "Tempra could not restore every process."
            )
        }
        await updatePauseWakeMonitoring()
        scheduleLimitScheduler()
        scheduleNextTick()
        return snapshot()
    }

    func performApplicationCommand(
        _ command: ApplicationCommand,
        bundleIdentifier: String
    ) async -> ApplicationCommandOutcome {
        guard !SoundSourceCompatibilityPolicy.isProtected(
            bundleIdentifier: bundleIdentifier
        ), groups[bundleIdentifier]?.isProtectedAudioInfrastructure != true else {
            return .failed(.compatibilityProtected)
        }

        guard groups[bundleIdentifier] != nil else {
            return .failed(.notRunning)
        }

        guard await restore(
            identifier: bundleIdentifier,
            resetDelay: true,
            attempts: restorationAttempts
        ) else {
            await markUnavailable(
                bundleIdentifier,
                detail: "Tempra could not restore every process before the app command."
            )
            await finishApplicationCommand()
            return .failed(.restorationFailed)
        }

        await setStatus(.normal, for: bundleIdentifier)
        let requestAccepted = switch command {
        case .bringToFront:
            if groups[bundleIdentifier]?.usesApplicationCommands == true {
                await activateApplication(bundleIdentifier)
            } else { false }
        case .hide:
            if groups[bundleIdentifier]?.usesApplicationCommands == true {
                await hideApplication(bundleIdentifier)
            } else { false }
        case .quit:
            if let group = groups[bundleIdentifier] {
                await requestTermination(for: group)
            } else { false }
        }

        guard requestAccepted else {
            await emitActivity(
                bundleIdentifier,
                kind: .error,
                detail: "macOS did not accept the requested app command."
            )
            await finishApplicationCommand()
            return .failed(.requestRejected)
        }

        switch command {
        case .bringToFront:
            break
        case .hide:
            hideRequested.insert(bundleIdentifier)
        case .quit:
            quitRequested.insert(bundleIdentifier)
            await setStatus(.waiting, for: bundleIdentifier)
            await emitActivity(
                bundleIdentifier,
                kind: .quit,
                detail: "Force quit from the process menu"
            )
        }

        await finishApplicationCommand()
        return .succeeded
    }

    @discardableResult
    func restoreAll(attempts: Int = 3) async -> ProcessRestorationResult {
        tickTask?.cancel()
        tickTask = nil
        scheduledTickInterval = nil
        scheduledTickDeadline = nil
        resetLimitScheduler()

        for identifier in trackedIdentifiers {
            let restored = await restore(
                identifier: identifier,
                resetDelay: true,
                attempts: attempts
            )
            guard workIsCurrent else { return restorationResult() }
            if restored {
                await setStatus(.normal, for: identifier)
            } else {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore every process."
                )
            }
            guard workIsCurrent else { return restorationResult() }
        }
        statuses = statuses.filter { $0.value == .unavailable }
        audioProtection.removeAll()
        await updatePauseWakeMonitoring()
        guard workIsCurrent else { return restorationResult() }
        let result = restorationResult()
        if result.succeeded {
            await crashWatchdog.disarm()
        }
        return result
    }

    func wakePausedApplicationsForUserActivation() async {
        guard isEnabled else { return }
        let until = Date().addingTimeInterval(userActivationProbeDuration)
        for identifier in Array(stoppedByTempra.keys) where rules[identifier]?.action == .pause {
            let stopped = stoppedByTempra[identifier, default: []]
            let result = await system.resume(stopped)
            let synchronized = await setStoppedProcesses(result.failed, for: identifier)
            if !synchronized {
                await markUnavailable(
                    identifier,
                    detail: "Tempra lost its process safety helper while resuming processes."
                )
            }
            if !result.applied.isEmpty {
                pauseActivationProbeUntil[identifier] = until
            }
        }
        await updatePauseWakeMonitoring()
        scheduleLimitScheduler()
        scheduleNextTick()
    }

    func currentSnapshot() -> ProcessControlSnapshot {
        snapshot()
    }

    @discardableResult
    func shutdown() async -> ProcessRestorationResult {
        stateID = UUID()
        isEnabled = false
        needsStateReconciliation = true
        await drainReconciliationQueue()
        let result = restorationResult()
        if result.succeeded {
            eventHandler = nil
        }
        return result
    }

    private var trackedIdentifiers: Set<String> {
        Set(statuses.keys)
            .union(stoppedByTempra.keys)
            .union(backgroundedByTempra.keys)
            .union(limitRuntimes.keys)
            .union(pausedBaselineCPU.keys)
            .union(pauseActivationProbeUntil.keys)
    }

    private func tick(trigger: ProcessControlTickTrigger) async {
        if trigger == .cadence {
            tickTask = nil
            scheduledTickInterval = nil
            scheduledTickDeadline = nil
        }
        guard workIsCurrent, isEnabled else {
            await updatePauseWakeMonitoring()
            return
        }
        let now = Date()
        if trigger == .cadence {
            refreshWindowVisibility()
        }

        for (identifier, rule) in rules where rule.hasBehavior {
            guard workIsCurrent else { return }
            guard let app = groups[identifier] else { continue }

            if quitRequested.contains(identifier), statuses[identifier] != .unavailable {
                await setStatus(.waiting, for: identifier)
                continue
            }

            let isAudioProtected = audioProtection.update(
                identifier: identifier,
                isPlayingAudio: app.isPlayingAudio,
                protectsAudio: rule.protectAudio,
                now: clock.now(),
                releaseDelay: ProcessControlMath.duration(audioProtectionReleaseDelay)
            )
            let appIsFrontmost = await isFrontmost(app)
            guard workIsCurrent else { return }
            if appIsFrontmost {
                let restored = await restore(
                    identifier: identifier,
                    resetDelay: true,
                    attempts: restorationAttempts
                )
                guard workIsCurrent else { return }
                if restored {
                    await setStatus(.normal, for: identifier)
                } else {
                    await markUnavailable(
                        identifier,
                        detail: "Tempra could not restore every process."
                    )
                }
                continue
            }

            let isWithinLaunchGrace = app.launchedAt.map {
                now < $0.addingTimeInterval(Self.launchGracePeriod)
            } ?? false

            if app.isProtectedByMenuBarOverlay {
                backgroundSince.removeValue(forKey: identifier)
                hideRequested.remove(identifier)
                quitRequested.remove(identifier)
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesEfficiencyCores: !isWithinLaunchGrace
                ) {
                    guard workIsCurrent else { return }
                    await setStatus(
                        isWithinLaunchGrace
                            ? .waiting
                            : (rule.usesEfficiencyCoreScheduling ? .energyEfficient : .normal),
                        for: identifier
                    )
                }
                continue
            }

            if isAudioProtected {
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesEfficiencyCores: false
                ) {
                    guard workIsCurrent else { return }
                    backgroundSince[identifier] = Date()
                    await setStatus(.audioProtected, for: identifier)
                }
                continue
            }

            let backgroundStart = backgroundSince[identifier] ?? now
            backgroundSince[identifier] = backgroundStart
            let backgroundDuration = now.timeIntervalSince(backgroundStart)

            if isWithinLaunchGrace {
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesEfficiencyCores: false
                ) {
                    guard workIsCurrent else { return }
                    backgroundSince[identifier] = backgroundStart
                    await setStatus(.waiting, for: identifier)
                }
                continue
            }

            let didApplyIdleAction = await applyIdleActions(
                for: app,
                rule: rule,
                backgroundDuration: backgroundDuration
            )
            guard workIsCurrent else { return }
            if didApplyIdleAction {
                let restored = await restoreProcessControl(
                    identifier: identifier,
                    attempts: restorationAttempts
                )
                guard workIsCurrent else { return }
                if restored {
                    await setStatus(.waiting, for: identifier)
                } else {
                    await markUnavailable(
                        identifier,
                        detail: "Tempra could not restore every process after requesting force quit."
                    )
                }
                continue
            }

            if (rule.action != .none || rule.runOnEfficiencyCores),
               app.windowVisibility.protectsFromDisruptiveManagement {
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesEfficiencyCores: false
                ) {
                    guard workIsCurrent else { return }
                    backgroundSince[identifier] = backgroundStart
                    await setStatus(.waiting, for: identifier)
                }
                continue
            }

            if rule.onlyWhenHidden && !app.isHidden {
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesEfficiencyCores: false
                ) {
                    guard workIsCurrent else { return }
                    backgroundSince[identifier] = backgroundStart
                    await setStatus(.waiting, for: identifier)
                }
                continue
            }

            let startDelay = max(
                rule.delaySeconds,
                app.windowVisibility.minimumDisruptiveDelay
            )
            if rule.action != .none, backgroundDuration < startDelay {
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesEfficiencyCores: true
                ) {
                    guard workIsCurrent else { return }
                    backgroundSince[identifier] = backgroundStart
                    await setStatus(
                        rule.usesEfficiencyCoreScheduling ? .energyEfficient : .waiting,
                        for: identifier
                    )
                }
                continue
            }

            if (rule.action != .none || rule.runOnEfficiencyCores),
               app.processIdentities.isEmpty {
                await markUnavailable(
                    identifier,
                    detail: "Tempra does not have a verified process identity for this process. "
                        + "Administrator access may be required."
                )
                continue
            }

            guard workIsCurrent else { return }
            await apply(
                rule: rule,
                to: app,
                advancesLimitCycle: trigger == .cadence
            )
            guard workIsCurrent else { return }
        }
        await updatePauseWakeMonitoring()
        guard workIsCurrent else { return }
        scheduleLimitScheduler()
        scheduleNextTick()
    }

    private func apply(
        rule: AppRule,
        to app: ProcessControlTarget,
        advancesLimitCycle: Bool
    ) async {
        guard workIsCurrent else { return }
        let identifier = app.bundleIdentifier
        switch rule.action {
        case .none:
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            pausedBaselineCPU.removeValue(forKey: identifier)
            guard await resumeStoppedProcesses(for: identifier, attempts: restorationAttempts) else {
                await markUnavailable(identifier, detail: "Tempra could not resume every process.")
                return
            }
            guard workIsCurrent else { return }
            if rule.usesEfficiencyCoreScheduling {
                if await applyBackgroundPriority(to: app) {
                    guard workIsCurrent else { return }
                    await setStatus(.energyEfficient, for: identifier)
                }
            } else if await restoreBackgroundPriority(
                for: identifier,
                attempts: restorationAttempts
            ) {
                guard workIsCurrent else { return }
                await setStatus(.normal, for: identifier)
            } else {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore normal process priority."
                )
            }
        case .pause:
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            guard await restoreBackgroundPriority(
                for: identifier,
                attempts: restorationAttempts
            ) else {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore normal process priority before pausing."
                )
                return
            }
            guard workIsCurrent else { return }
            pausedBaselineCPU[identifier] = pausedBaselineCPU[identifier]
                ?? max(0, app.cpuPercent)
            if await maintainPause(for: app) {
                guard workIsCurrent else { return }
                await setStatus(.paused, for: identifier)
            }
        case .limit:
            pausedBaselineCPU.removeValue(forKey: identifier)
            guard await applyBackgroundPriority(to: app) else { return }
            guard workIsCurrent else { return }
            if advancesLimitCycle || limitRuntimes[identifier] == nil {
                await runLimitCycle(for: app, limitPercent: rule.limitPercent)
            } else {
                await maintainLimitCycle(for: app, limitPercent: rule.limitPercent)
            }
        }
    }

    private func applyIdleActions(
        for app: ProcessControlTarget,
        rule: AppRule,
        backgroundDuration: TimeInterval
    ) async -> Bool {
        guard workIsCurrent else { return false }
        let identifier = app.bundleIdentifier

        if let hideAfterMinutes = rule.hideAfterMinutes,
           app.usesApplicationCommands,
           backgroundDuration >= hideAfterMinutes * 60,
           !app.isHidden,
           !hideRequested.contains(identifier),
           await hideApplication(identifier) {
            guard workIsCurrent else { return false }
            hideRequested.insert(identifier)
            await emitActivity(
                identifier,
                kind: .hidden,
                detail: "Hidden after \(Int(hideAfterMinutes)) minutes"
            )
        }

        if let quitAfterMinutes = rule.quitAfterMinutes,
           backgroundDuration >= quitAfterMinutes * 60,
           !quitRequested.contains(identifier),
           await requestTermination(for: app) {
            guard workIsCurrent else { return false }
            quitRequested.insert(identifier)
            await emitActivity(
                identifier,
                kind: .quit,
                detail: "Force quit after \(Int(quitAfterMinutes)) minutes"
            )
            return true
        }
        return false
    }

    private func requestTermination(for app: ProcessControlTarget) async -> Bool {
        guard workIsCurrent else { return false }
        if app.usesApplicationCommands {
            return await forceTerminateApplication(app.bundleIdentifier)
        }
        let result = await system.terminate(app.processIdentities)
        return !result.applied.isEmpty && result.failed.isEmpty
    }

    private func maintainPause(for app: ProcessControlTarget) async -> Bool {
        guard workIsCurrent else { return false }
        let identifier = app.bundleIdentifier
        let now = Date()
        if let until = pauseActivationProbeUntil[identifier], now < until {
            return true
        }
        pauseActivationProbeUntil.removeValue(forKey: identifier)

        let existing = stoppedByTempra[identifier, default: []]
            .intersection(app.processIdentities)
        let processesToStop = app.processIdentities.subtracting(existing)
        guard await prepareWatchdogToStop(
            existing.union(processesToStop),
            for: identifier
        ) else {
            return false
        }
        guard workIsCurrent else { return false }
        let result = await system.stop(processesToStop)
        if !workIsCurrent {
            let stopped = existing.union(result.applied)
            _ = await setStoppedProcesses(stopped, for: identifier)
            return false
        }
        guard result.failed.isEmpty else {
            let rollback = await system.resume(existing.union(result.applied))
            _ = await setStoppedProcesses(rollback.failed, for: identifier)
            pausedBaselineCPU.removeValue(forKey: identifier)
            await markUnavailable(identifier, detail: "Tempra could not pause every process.")
            return false
        }

        let stopped = existing.union(result.applied)
        guard !stopped.isEmpty else {
            _ = await setStoppedProcesses([], for: identifier)
            pausedBaselineCPU.removeValue(forKey: identifier)
            await setStatus(.normal, for: identifier)
            return false
        }
        return await setStoppedProcesses(stopped, for: identifier)
    }

    private func applyBackgroundPriority(to app: ProcessControlTarget) async -> Bool {
        guard workIsCurrent else { return false }
        let identifier = app.bundleIdentifier
        let existing = backgroundedByTempra[identifier, default: []]
            .intersection(app.processIdentities)
        let result = await system.setBackgroundPriority(
            app.processIdentities.subtracting(existing)
        )
        if !workIsCurrent {
            backgroundedByTempra[identifier] = existing.union(result.applied)
            return false
        }
        guard result.failed.isEmpty else {
            let rollback = await system.restorePriority(existing.union(result.applied))
            backgroundedByTempra[identifier] = rollback.failed
            await markUnavailable(
                identifier,
                detail: "Tempra could not change every process to background priority."
            )
            return false
        }

        let backgrounded = existing.union(result.applied)
        guard !backgrounded.isEmpty else {
            backgroundedByTempra.removeValue(forKey: identifier)
            await setStatus(.normal, for: identifier)
            return false
        }
        backgroundedByTempra[identifier] = backgrounded
        return true
    }

    private func runLimitCycle(
        for app: ProcessControlTarget,
        limitPercent: Double
    ) async {
        guard workIsCurrent else { return }
        let identifier = app.bundleIdentifier
        let now = clock.now()
        guard let nowCPU = await readCPUTime(
            for: app.processIdentities,
            identifier: identifier
        ) else { return }
        let isStopped = stoppedByTempra[identifier]?.isEmpty == false
        let startsAboveLimit = app.cpuPercent
            > ProcessControlMath.activationThreshold(for: limitPercent)
        let initialCredit = controlInterval
            * max(0, limitPercent)
            / 100
            * 1_000_000_000
        var runtime = limitRuntimes[identifier] ?? LimitRuntime(
            lastCPUNanoseconds: nowCPU,
            lastAccountingAt: now,
            runStartedAt: isStopped ? nil : now,
            estimatedFullSpeedCPU: max(app.cpuPercent, limitPercent, 1),
            cpuCreditNanoseconds: initialCredit,
            lastMeasuredCPUPercent: nil,
            stoppedAt: isStopped ? now : nil,
            generation: 0,
            phase: isStopped ? .stopped : (startsAboveLimit ? .running : .observing),
            processIdentities: app.processIdentities
        )
        var accountingElapsed = max(
            0,
            ProcessControlMath.timeInterval(runtime.lastAccountingAt.duration(to: now))
        )

        if runtime.processIdentities != app.processIdentities {
            runtime = LimitRuntime(
                lastCPUNanoseconds: nowCPU,
                lastAccountingAt: now,
                runStartedAt: isStopped ? nil : now,
                estimatedFullSpeedCPU: max(app.cpuPercent, limitPercent, 1),
                cpuCreditNanoseconds: initialCredit,
                lastMeasuredCPUPercent: nil,
                stoppedAt: isStopped ? now : nil,
                generation: runtime.generation,
                phase: isStopped ? .stopped : (startsAboveLimit ? .running : .observing),
                processIdentities: app.processIdentities
            )
            accountingElapsed = 0
        } else if runtime.phase != .observing
                    || accountingElapsed >= limitObservationInterval {
            _ = updateLimitAccounting(
                runtime: &runtime,
                nowCPU: nowCPU,
                now: now,
                limitPercent: limitPercent
            )
        }

        if runtime.phase == .observing {
            if accountingElapsed < limitObservationInterval {
                scheduleLimitObservation(
                    for: identifier,
                    runtime: runtime,
                    limitPercent: limitPercent,
                    now: now,
                    after: limitObservationInterval - accountingElapsed
                )
                limitRuntimes[identifier] = runtime
                await setStatus(.energyEfficient, for: identifier)
                return
            }

            let measuredCPU = runtime.lastMeasuredCPUPercent ?? 0
            if measuredCPU <= ProcessControlMath.activationThreshold(for: limitPercent) {
                runtime.cpuCreditNanoseconds = initialCredit
                runtime.generation = ProcessControlMath.nextGeneration(after: runtime.generation)
                scheduleLimitObservation(
                    for: identifier,
                    runtime: runtime,
                    limitPercent: limitPercent,
                    now: now,
                    after: limitObservationInterval
                )
                limitRuntimes[identifier] = runtime
                await setStatus(.energyEfficient, for: identifier)
                return
            }

            runtime.phase = .running
            runtime.runStartedAt = now
            runtime.cpuCreditNanoseconds = 0
        } else if runtime.phase == .running,
                  let measuredCPU = runtime.lastMeasuredCPUPercent,
                  measuredCPU <= ProcessControlMath.releaseThreshold(for: limitPercent) {
            runtime.phase = .observing
            runtime.runStartedAt = now
            runtime.cpuCreditNanoseconds = initialCredit
            runtime.generation = ProcessControlMath.nextGeneration(after: runtime.generation)
            scheduleLimitObservation(
                for: identifier,
                runtime: runtime,
                limitPercent: limitPercent,
                now: now,
                after: limitObservationInterval
            )
            limitRuntimes[identifier] = runtime
            await setStatus(.energyEfficient, for: identifier)
            return
        }

        let estimatedCPUPerWallSecond = max(runtime.estimatedFullSpeedCPU / 100, 0.01)
        let affordableRunDuration = max(0, runtime.cpuCreditNanoseconds)
            / (estimatedCPUPerWallSecond * 1_000_000_000)
        var runDuration = min(controlInterval, affordableRunDuration)
        if runDuration < minimumRunDuration, runtime.phase == .stopped {
            let stoppedAt = runtime.stoppedAt ?? now
            runtime.stoppedAt = stoppedAt
            if now >= stoppedAt.advanced(
                by: ProcessControlMath.duration(maximumLimitStopDuration)
            ) {
                runDuration = minimumRunDuration
            }
        }
        runtime.lastCPUNanoseconds = nowCPU
        runtime.generation = ProcessControlMath.nextGeneration(after: runtime.generation)
        let generation = runtime.generation
        limitRuntimes[identifier] = runtime
        limitDeadlines.remove(identifier: identifier)

        guard runDuration >= minimumRunDuration else {
            if runtime.phase == .stopped {
                scheduleLimitEvaluation(
                    for: identifier,
                    runtime: runtime,
                    limitPercent: limitPercent,
                    now: now
                )
                await setStatus(.limited(limitPercent), for: identifier)
                return
            }
            await finishLimitCycle(
                identifier: identifier,
                generation: generation,
                limitPercent: limitPercent,
                processIdentities: app.processIdentities
            )
            return
        }

        guard await resumeStoppedProcesses(for: identifier, attempts: restorationAttempts) else {
            await markUnavailable(identifier, detail: "Tempra could not resume every process.")
            return
        }

        guard let resumedCPUTime = await readCPUTime(
            for: app.processIdentities,
            identifier: identifier
        ) else { return }
        runtime.lastCPUNanoseconds = resumedCPUTime
        runtime.lastAccountingAt = clock.now()
        runtime.runStartedAt = runtime.lastAccountingAt
        runtime.stoppedAt = nil
        runtime.phase = .running
        runtime.processIdentities = app.processIdentities

        guard runDuration < controlInterval * 0.98 else {
            limitRuntimes[identifier] = runtime
            limitDeadlines.upsert(LimitDeadline(
                identifier: identifier,
                deadline: runtime.lastAccountingAt.advanced(
                    by: ProcessControlMath.duration(runningLimitRecheckInterval)
                ),
                generation: generation,
                limitPercent: limitPercent,
                processIdentities: app.processIdentities,
                kind: .evaluate
            ))
            await setStatus(.limited(limitPercent), for: identifier)
            return
        }

        let stopDeadline = runtime.lastAccountingAt.advanced(
            by: ProcessControlMath.duration(runDuration)
        )
        limitRuntimes[identifier] = runtime
        limitDeadlines.upsert(LimitDeadline(
            identifier: identifier,
            deadline: stopDeadline,
            generation: generation,
            limitPercent: limitPercent,
            processIdentities: app.processIdentities,
            kind: .stop
        ))
        await setStatus(.limited(limitPercent), for: identifier)
    }

    @discardableResult
    private func updateLimitAccounting(
        runtime: inout LimitRuntime,
        nowCPU: UInt64,
        now: ContinuousClock.Instant,
        limitPercent: Double
    ) -> Double? {
        let elapsed = max(
            0,
            ProcessControlMath.timeInterval(runtime.lastAccountingAt.duration(to: now))
        )
        let allowedCPUPerSecond = max(0, limitPercent) / 100 * 1_000_000_000
        runtime.cpuCreditNanoseconds += elapsed * allowedCPUPerSecond

        var measuredCPUPercent: Double?
        if let runStartedAt = runtime.runStartedAt,
           nowCPU >= runtime.lastCPUNanoseconds {
            let runDuration = max(
                0,
                ProcessControlMath.timeInterval(runStartedAt.duration(to: now))
            )
            let consumed = Double(nowCPU - runtime.lastCPUNanoseconds)
            if runDuration >= minimumDemandSampleDuration {
                let measuredFullSpeed = consumed / (runDuration * 1_000_000_000) * 100
                measuredCPUPercent = measuredFullSpeed
                runtime.lastMeasuredCPUPercent = measuredFullSpeed
                if measuredFullSpeed > 0.5 {
                    runtime.estimatedFullSpeedCPU = runtime.estimatedFullSpeedCPU * 0.65
                        + measuredFullSpeed * 0.35
                }
            }
            runtime.cpuCreditNanoseconds -= consumed
        }

        let estimatedCPUPerWallSecond = max(runtime.estimatedFullSpeedCPU / 100, 0.01)
        let minimumSliceCost = minimumRunDuration
            * estimatedCPUPerWallSecond
            * 1_000_000_000
        let maximumCredit = max(
            controlInterval * allowedCPUPerSecond,
            minimumSliceCost
        )
        let maximumDebt = max(allowedCPUPerSecond, minimumSliceCost)
        runtime.cpuCreditNanoseconds = min(
            maximumCredit,
            max(-maximumDebt, runtime.cpuCreditNanoseconds)
        )
        runtime.lastCPUNanoseconds = nowCPU
        runtime.lastAccountingAt = now
        runtime.runStartedAt = runtime.phase == .stopped ? nil : now
        return measuredCPUPercent
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
            processIdentities: runtime.processIdentities,
            kind: .evaluate
        ))
    }

    private func scheduleLimitEvaluation(
        for identifier: String,
        runtime: LimitRuntime,
        limitPercent: Double,
        now: ContinuousClock.Instant
    ) {
        let estimatedCPUPerWallSecond = max(runtime.estimatedFullSpeedCPU / 100, 0.01)
        let minimumSliceCost = minimumRunDuration
            * estimatedCPUPerWallSecond
            * 1_000_000_000
        let creditNeeded = max(0, minimumSliceCost - runtime.cpuCreditNanoseconds)
        let allowedCPUPerSecond = max(0, limitPercent) / 100 * 1_000_000_000
        let creditWait = allowedCPUPerSecond > 0
            ? creditNeeded / allowedCPUPerSecond
            : maximumLimitStopDuration
        let creditDeadline = now.advanced(
            by: ProcessControlMath.duration(max(0.001, creditWait))
        )
        let responsivenessDeadline = (runtime.stoppedAt ?? now).advanced(
            by: ProcessControlMath.duration(maximumLimitStopDuration)
        )
        limitDeadlines.upsert(LimitDeadline(
            identifier: identifier,
            deadline: min(creditDeadline, responsivenessDeadline),
            generation: runtime.generation,
            limitPercent: limitPercent,
            processIdentities: runtime.processIdentities,
            kind: .evaluate
        ))
    }

    private func maintainLimitCycle(
        for app: ProcessControlTarget,
        limitPercent: Double
    ) async {
        guard workIsCurrent else { return }
        let identifier = app.bundleIdentifier
        guard let runtime = limitRuntimes[identifier] else { return }

        if runtime.processIdentities != app.processIdentities {
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            await runLimitCycle(for: app, limitPercent: limitPercent)
            return
        }

        guard runtime.phase == .stopped else {
            await setStatus(
                runtime.phase == .observing ? .energyEfficient : .limited(limitPercent),
                for: identifier
            )
            return
        }

        guard await prepareWatchdogToStop(app.processIdentities, for: identifier) else {
            limitRuntimes.removeValue(forKey: identifier)
            return
        }
        let result = await system.stop(app.processIdentities)
        guard workIsCurrent else {
            await trackStoppedProcessesFromStaleWork(result.applied, for: identifier)
            return
        }
        guard result.failed.isEmpty else {
            let rollback = await system.resume(result.applied)
            _ = await setStoppedProcesses(rollback.failed, for: identifier)
            let priorityRollback = await system.restorePriority(
                backgroundedByTempra[identifier, default: []]
            )
            if priorityRollback.failed.isEmpty {
                backgroundedByTempra.removeValue(forKey: identifier)
            } else {
                backgroundedByTempra[identifier] = priorityRollback.failed
            }
            limitRuntimes.removeValue(forKey: identifier)
            await markUnavailable(identifier, detail: "Tempra could not limit every process.")
            return
        }
        guard !result.applied.isEmpty else {
            _ = await setStoppedProcesses([], for: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            await setStatus(.normal, for: identifier)
            return
        }
        guard await setStoppedProcesses(result.applied, for: identifier) else {
            limitRuntimes.removeValue(forKey: identifier)
            return
        }
        guard workIsCurrent else { return }
        await setStatus(.limited(limitPercent), for: identifier)
    }

    private func finishLimitCycle(
        identifier: String,
        generation: UInt64,
        limitPercent: Double,
        processIdentities: Set<ProcessIdentity>
    ) async {
        guard workIsCurrent,
              let runtime = limitRuntimes[identifier],
              runtime.generation == generation,
              runtime.processIdentities == processIdentities else {
            return
        }
        guard isEnabled,
              let app = groups[identifier],
              app.processIdentities == processIdentities,
              rules[identifier]?.action == .limit else {
            return
        }
        let appIsFrontmost = await isFrontmost(app)
        guard workIsCurrent else { return }
        if appIsFrontmost {
            if await restore(
                identifier: identifier,
                resetDelay: true,
                attempts: restorationAttempts
            ) {
                await setStatus(.normal, for: identifier)
            } else {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore every process."
                )
            }
            scheduleNextTick()
            return
        }
        guard isEnabled,
              let currentApp = groups[identifier],
              currentApp.processIdentities == processIdentities,
              limitRuntimes[identifier]?.generation == generation,
              rules[identifier]?.action == .limit else {
            return
        }

        guard await prepareWatchdogToStop(processIdentities, for: identifier) else {
            limitRuntimes.removeValue(forKey: identifier)
            scheduleNextTick()
            return
        }
        let result = await system.stop(processIdentities)
        guard workIsCurrent else {
            await trackStoppedProcessesFromStaleWork(result.applied, for: identifier)
            return
        }
        guard result.failed.isEmpty else {
            let rollback = await system.resume(result.applied)
            _ = await setStoppedProcesses(rollback.failed, for: identifier)
            let priorityRollback = await system.restorePriority(
                backgroundedByTempra[identifier, default: []]
            )
            if priorityRollback.failed.isEmpty {
                backgroundedByTempra.removeValue(forKey: identifier)
            } else {
                backgroundedByTempra[identifier] = priorityRollback.failed
            }
            limitRuntimes.removeValue(forKey: identifier)
            await markUnavailable(identifier, detail: "Tempra could not limit every process.")
            scheduleNextTick()
            return
        }
        guard !result.applied.isEmpty else {
            _ = await setStoppedProcesses([], for: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            await setStatus(.normal, for: identifier)
            scheduleNextTick()
            return
        }
        guard await setStoppedProcesses(result.applied, for: identifier) else {
            limitRuntimes.removeValue(forKey: identifier)
            scheduleNextTick()
            return
        }
        guard workIsCurrent else { return }
        if var runtime = limitRuntimes[identifier], runtime.generation == generation {
            let stoppedAt = clock.now()
            guard let stoppedCPUTime = await readCPUTime(
                for: currentApp.processIdentities,
                identifier: identifier
            ) else {
                guard workIsCurrent else { return }
                limitRuntimes.removeValue(forKey: identifier)
                scheduleNextTick()
                return
            }
            let measuredCPU = updateLimitAccounting(
                runtime: &runtime,
                nowCPU: stoppedCPUTime,
                now: stoppedAt,
                limitPercent: limitPercent
            )
            if let measuredCPU,
               measuredCPU <= ProcessControlMath.releaseThreshold(for: limitPercent) {
                guard await resumeStoppedProcesses(
                    for: identifier,
                    attempts: restorationAttempts
                ) else {
                    limitRuntimes.removeValue(forKey: identifier)
                    await markUnavailable(
                        identifier,
                        detail: "Tempra could not resume an app after its CPU use fell below the limit."
                    )
                    scheduleNextTick()
                    return
                }
                let observationStartedAt = clock.now()
                guard let observationCPUTime = await readCPUTime(
                    for: currentApp.processIdentities,
                    identifier: identifier
                ) else {
                    guard workIsCurrent else { return }
                    limitRuntimes.removeValue(forKey: identifier)
                    scheduleNextTick()
                    return
                }
                runtime.lastCPUNanoseconds = observationCPUTime
                runtime.lastAccountingAt = observationStartedAt
                runtime.runStartedAt = observationStartedAt
                runtime.cpuCreditNanoseconds = controlInterval
                    * max(0, limitPercent)
                    / 100
                    * 1_000_000_000
                runtime.stoppedAt = nil
                runtime.phase = .observing
                runtime.generation = ProcessControlMath.nextGeneration(
                    after: runtime.generation
                )
                runtime.processIdentities = currentApp.processIdentities
                limitRuntimes[identifier] = runtime
                scheduleLimitObservation(
                    for: identifier,
                    runtime: runtime,
                    limitPercent: limitPercent,
                    now: observationStartedAt,
                    after: limitObservationInterval
                )
                await setStatus(.energyEfficient, for: identifier)
                await updatePauseWakeMonitoring()
                return
            }
            runtime.phase = .stopped
            runtime.runStartedAt = nil
            runtime.stoppedAt = stoppedAt
            runtime.generation = ProcessControlMath.nextGeneration(after: runtime.generation)
            runtime.processIdentities = currentApp.processIdentities
            limitRuntimes[identifier] = runtime
            scheduleLimitEvaluation(
                for: identifier,
                runtime: runtime,
                limitPercent: limitPercent,
                now: stoppedAt
            )
        }
        await setStatus(.limited(limitPercent), for: identifier)
        await updatePauseWakeMonitoring()
    }

    private func reconcileControlledProcesses() async {
        guard workIsCurrent else { return }
        for identifier in Set(stoppedByTempra.keys).union(backgroundedByTempra.keys) {
            guard workIsCurrent else { return }
            let current = groups[identifier]?.processIdentities ?? []

            let retiredStopped = stoppedByTempra[identifier, default: []].subtracting(current)
            if !retiredStopped.isEmpty {
                let result = await system.resume(retiredStopped)
                let remaining = stoppedByTempra[identifier, default: []]
                    .subtracting(result.applied.union(result.stale))
                _ = await setStoppedProcesses(remaining, for: identifier)
                guard workIsCurrent else { return }
            }

            let retiredBackgrounded = backgroundedByTempra[identifier, default: []]
                .subtracting(current)
            if !retiredBackgrounded.isEmpty {
                let result = await system.restorePriority(retiredBackgrounded)
                backgroundedByTempra[identifier]?.subtract(result.applied.union(result.stale))
                guard workIsCurrent else { return }
            }
        }
        await updatePauseWakeMonitoring()
    }

    private func restore(
        identifier: String,
        resetDelay: Bool,
        attempts: Int
    ) async -> Bool {
        let resumed = await restoreDisruptiveControl(identifier: identifier, attempts: attempts)
        guard workIsCurrent else { return false }
        let priorityRestored = await restoreBackgroundPriority(
            for: identifier,
            attempts: attempts
        )
        guard workIsCurrent else { return false }
        if resetDelay {
            backgroundSince.removeValue(forKey: identifier)
            hideRequested.remove(identifier)
            quitRequested.remove(identifier)
        }
        return resumed && priorityRestored
    }

    private func restoreProcessControl(identifier: String, attempts: Int) async -> Bool {
        let resumed = await restoreDisruptiveControl(identifier: identifier, attempts: attempts)
        guard workIsCurrent else { return false }
        let priorityRestored = await restoreBackgroundPriority(
            for: identifier,
            attempts: attempts
        )
        return resumed && priorityRestored && workIsCurrent
    }

    private func restoreDisruptiveControl(identifier: String, attempts: Int) async -> Bool {
        guard workIsCurrent else { return false }
        limitDeadlines.remove(identifier: identifier)
        limitRuntimes.removeValue(forKey: identifier)
        pausedBaselineCPU.removeValue(forKey: identifier)
        pauseActivationProbeUntil.removeValue(forKey: identifier)
        return await resumeStoppedProcesses(for: identifier, attempts: attempts)
    }

    private func prepareForDeferredAction(
        rule: AppRule,
        app: ProcessControlTarget,
        appliesEfficiencyCores: Bool
    ) async -> Bool {
        guard workIsCurrent else { return false }
        let identifier = app.bundleIdentifier
        guard await restoreDisruptiveControl(
            identifier: identifier,
            attempts: restorationAttempts
        ) else {
            await markUnavailable(identifier, detail: "Tempra could not restore every process.")
            return false
        }
        guard workIsCurrent else { return false }

        if appliesEfficiencyCores, rule.usesEfficiencyCoreScheduling {
            return await applyBackgroundPriority(to: app)
        }
        guard await restoreBackgroundPriority(
            for: identifier,
            attempts: restorationAttempts
        ) else {
            await markUnavailable(
                identifier,
                detail: "Tempra could not restore normal process priority."
            )
            return false
        }
        return workIsCurrent
    }

    private func resumeStoppedProcesses(for identifier: String, attempts: Int) async -> Bool {
        let unresolved = await performWithRetries(
            stoppedByTempra[identifier, default: []],
            attempts: attempts,
            operation: { await system.resume($0) }
        )
        let synchronized = await setStoppedProcesses(unresolved, for: identifier)
        return unresolved.isEmpty && synchronized && workIsCurrent
    }

    private func trackStoppedProcessesFromStaleWork(
        _ processes: Set<ProcessIdentity>,
        for identifier: String
    ) async {
        guard !processes.isEmpty else { return }
        let stopped = stoppedByTempra[identifier, default: []].union(processes)
        _ = await setStoppedProcesses(stopped, for: identifier)
    }

    private var allStoppedProcesses: Set<ProcessIdentity> {
        stoppedByTempra.values.reduce(into: Set<ProcessIdentity>()) {
            $0.formUnion($1)
        }
    }

    private func prepareWatchdogToStop(
        _ processes: Set<ProcessIdentity>,
        for identifier: String
    ) async -> Bool {
        guard workIsCurrent else { return false }
        guard !processes.isEmpty else { return true }
        do {
            try await crashWatchdog.prepareToStop(processes)
            guard workIsCurrent else {
                _ = await setStoppedProcesses(
                    stoppedByTempra[identifier, default: []],
                    for: identifier
                )
                return false
            }
            return true
        } catch {
            await markUnavailable(identifier, detail: error.localizedDescription)
            return false
        }
    }

    private func setStoppedProcesses(
        _ processes: Set<ProcessIdentity>,
        for identifier: String
    ) async -> Bool {
        if processes.isEmpty {
            stoppedByTempra.removeValue(forKey: identifier)
        } else {
            stoppedByTempra[identifier] = processes
        }

        do {
            try await crashWatchdog.synchronize(allStoppedProcesses)
            return true
        } catch {
            let pending = allStoppedProcesses
            let emergencyResult = await system.resume(pending)
            for trackedIdentifier in Array(stoppedByTempra.keys) {
                let unresolved = stoppedByTempra[trackedIdentifier, default: []]
                    .intersection(emergencyResult.failed)
                if unresolved.isEmpty {
                    stoppedByTempra.removeValue(forKey: trackedIdentifier)
                } else {
                    stoppedByTempra[trackedIdentifier] = unresolved
                }
            }
            let affectedIdentifiers = stoppedByTempra.compactMap { trackedIdentifier, processes in
                processes.isEmpty ? nil : trackedIdentifier
            }
            let identifiersToMark = affectedIdentifiers.isEmpty
                ? [identifier]
                : affectedIdentifiers.sorted()
            for trackedIdentifier in identifiersToMark {
                await markUnavailable(
                    trackedIdentifier,
                    detail: error.localizedDescription
                        + " Tempra stopped management and attempted an immediate resume."
                )
            }
            return false
        }
    }

    private func restorationResult() -> ProcessRestorationResult {
        ProcessRestorationState.result(
            stoppedByIdentifier: stoppedByTempra,
            backgroundedByIdentifier: backgroundedByTempra
        )
    }

    private func restoreBackgroundPriority(for identifier: String, attempts: Int) async -> Bool {
        let unresolved = await performWithRetries(
            backgroundedByTempra[identifier, default: []],
            attempts: attempts,
            operation: { await system.restorePriority($0) }
        )
        if unresolved.isEmpty {
            backgroundedByTempra.removeValue(forKey: identifier)
            return workIsCurrent
        }
        backgroundedByTempra[identifier] = unresolved
        return false
    }

    private func performWithRetries(
        _ processes: Set<ProcessIdentity>,
        attempts: Int,
        operation: (Set<ProcessIdentity>) async -> ProcessOperationResult
    ) async -> Set<ProcessIdentity> {
        var unresolved = processes
        guard !unresolved.isEmpty else { return [] }

        for attempt in 0..<max(1, attempts) {
            guard workIsCurrent else { break }
            let result = await operation(unresolved)
            unresolved = result.failed
            guard workIsCurrent else { break }
            if unresolved.isEmpty { break }
            if attempt + 1 < attempts {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return unresolved
    }

    private func isFrontmost(_ app: ProcessControlTarget) async -> Bool {
        if app.isFrontmost { return true }
        let frontmostIdentifier = await frontmostProvider()
        return frontmostIdentifier == app.bundleIdentifier
    }

    private func readCPUTime(
        for processes: Set<ProcessIdentity>,
        identifier: String
    ) async -> UInt64? {
        do {
            let cpuTime = try await system.totalCPUTime(for: processes)
            return workIsCurrent ? cpuTime : nil
        } catch {
            await markUnavailable(
                identifier,
                detail: "Tempra could not read verified CPU time: "
                    + error.localizedDescription
            )
            return nil
        }
    }

    private func setStatus(_ status: ManagementStatus, for identifier: String) async {
        guard workIsCurrent else { return }
        let previous = statuses[identifier] ?? .normal
        statuses[identifier] = status
        guard previous != status else { return }
        await eventHandler?(.statusTransition(
            revision: eventRevision,
            bundleIdentifier: identifier,
            previous: previous,
            current: status
        ))
    }

    private func markUnavailable(_ identifier: String, detail: String) async {
        guard workIsCurrent else { return }
        let shouldRecord = statuses[identifier] != .unavailable
        await setStatus(.unavailable, for: identifier)
        if shouldRecord {
            await emitActivity(identifier, kind: .error, detail: detail)
        }
    }

    private func emitActivity(_ identifier: String, kind: ActivityKind, detail: String) async {
        guard workIsCurrent else { return }
        await eventHandler?(.activity(
            revision: eventRevision,
            bundleIdentifier: identifier,
            kind: kind,
            detail: detail
        ))
    }

    private func finishApplicationCommand() async {
        await updatePauseWakeMonitoring()
        scheduleLimitScheduler()
        scheduleNextTick()
    }

    private func updatePauseWakeMonitoring() async {
        guard workIsCurrent else { return }
        let needsMonitoring = stoppedByTempra.contains { identifier, processes in
            !processes.isEmpty && rules[identifier]?.action == .pause
        }
        guard needsMonitoring != isPauseWakeMonitoringEnabled else { return }
        isPauseWakeMonitoringEnabled = needsMonitoring
        await eventHandler?(.pauseWakeMonitoringChanged(
            revision: eventRevision,
            enabled: needsMonitoring
        ))
    }

    private func scheduleLimitScheduler() {
        guard isEnabled, let nextDeadline = limitDeadlines.first else {
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
        limitSchedulerTask = Task { [weak self, clock] in
            await clock.sleepUntil(deadline)
            guard !Task.isCancelled else { return }
            await self?.requestLimitDeadlineProcessing(
                schedulerGeneration: schedulerGeneration
            )
        }
    }

    private func processLimitDeadlines(
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
            switch deadline.kind {
            case .stop:
                await finishLimitCycle(
                    identifier: deadline.identifier,
                    generation: deadline.generation,
                    limitPercent: deadline.limitPercent,
                    processIdentities: deadline.processIdentities
                )
            case .evaluate:
                await evaluateLimitDeadline(deadline)
            }
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

    private func resetLimitScheduler() {
        limitSchedulerTask?.cancel()
        limitSchedulerTask = nil
        scheduledLimitDeadline = nil
        pendingLimitSchedulerGeneration = nil
        limitSchedulerGeneration = ProcessControlMath.nextGeneration(
            after: limitSchedulerGeneration
        )
        limitDeadlines.removeAll()
    }

    private func evaluateLimitDeadline(_ deadline: LimitDeadline) async {
        guard workIsCurrent,
              isEnabled,
              let runtime = limitRuntimes[deadline.identifier],
              runtime.generation == deadline.generation,
              runtime.processIdentities == deadline.processIdentities,
              let rule = rules[deadline.identifier],
              rule.action == .limit,
              let app = groups[deadline.identifier],
              app.processIdentities == deadline.processIdentities else {
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

    private func scheduleNextTick(now: Date = Date()) {
        guard isEnabled else { return }
        let audioClockNow = clock.now()
        var nextInterval: TimeInterval?
        func include(_ interval: TimeInterval) {
            let normalized = max(0.001, interval)
            nextInterval = min(nextInterval ?? normalized, normalized)
        }

        for (identifier, rule) in rules where rule.hasBehavior {
            guard let app = groups[identifier],
                  !app.isFrontmost,
                  !app.isProtectedByMenuBarOverlay else {
                continue
            }
            if statuses[identifier] == .unavailable {
                include(failureRetryInterval)
                continue
            }
            if let until = pauseActivationProbeUntil[identifier] {
                include(until.timeIntervalSince(now))
            }
            switch audioProtection.state(for: identifier) {
            case .playing:
                continue
            case .releaseDelay(let until) where audioClockNow < until:
                include(ProcessControlMath.timeInterval(audioClockNow.duration(to: until)))
                continue
            case .releaseDelay, nil:
                break
            }
            guard !(rule.protectAudio && app.isPlayingAudio) else { continue }
            let backgroundStart = backgroundSince[identifier] ?? now
            if let launchedAt = app.launchedAt {
                let launchGraceDeadline = launchedAt.addingTimeInterval(Self.launchGracePeriod)
                if launchGraceDeadline > now {
                    include(launchGraceDeadline.timeIntervalSince(now))
                    continue
                }
            }
            if let hideAfterMinutes = rule.hideAfterMinutes,
               !app.isHidden,
               !hideRequested.contains(identifier) {
                include(backgroundStart.addingTimeInterval(hideAfterMinutes * 60).timeIntervalSince(now))
            }
            if let quitAfterMinutes = rule.quitAfterMinutes,
               !quitRequested.contains(identifier) {
                include(backgroundStart.addingTimeInterval(quitAfterMinutes * 60).timeIntervalSince(now))
            }
            if rule.action != .none || rule.runOnEfficiencyCores {
                include(visibilityRecheckInterval)
            }
            if (rule.action != .none || rule.runOnEfficiencyCores),
               app.windowVisibility.protectsFromDisruptiveManagement {
                continue
            }
            guard !(rule.onlyWhenHidden && !app.isHidden), rule.action != .none else {
                continue
            }
            let ruleStart = backgroundStart.addingTimeInterval(max(
                rule.delaySeconds,
                app.windowVisibility.minimumDisruptiveDelay
            ))
            if ruleStart > now {
                include(ruleStart.timeIntervalSince(now))
            }
        }

        guard let nextInterval else {
            tickTask?.cancel()
            tickTask = nil
            scheduledTickInterval = nil
            scheduledTickDeadline = nil
            return
        }
        let clockNow = clock.now()
        let proposedDeadline = clockNow.advanced(
            by: ProcessControlMath.duration(nextInterval)
        )
        if tickTask != nil,
           let scheduledTickDeadline,
           scheduledTickDeadline <= proposedDeadline {
            scheduledTickInterval = max(
                0,
                ProcessControlMath.timeInterval(clockNow.duration(to: scheduledTickDeadline))
            )
            return
        }

        tickTask?.cancel()
        scheduledTickInterval = nextInterval
        scheduledTickDeadline = proposedDeadline
        tickTask = Task { [weak self, clock] in
            await clock.sleepUntil(proposedDeadline)
            guard !Task.isCancelled else { return }
            await self?.requestCadenceTick()
        }
    }

    private func refreshWindowVisibility() {
        let snapshot = windowSnapshotProvider()
        var identifiers: [String] = []
        var requests: [WindowVisibilitySnapshot.Request] = []
        for (identifier, rule) in rules where rule.hasBehavior {
            guard let app = groups[identifier] else { continue }
            identifiers.append(identifier)
            requests.append(WindowVisibilitySnapshot.Request(
                processIdentifiers: Set(app.processIdentities.map(\.pid)),
                isHidden: false
            ))
        }
        let visibilities = snapshot?.visibilities(for: requests)
        for (index, identifier) in identifiers.enumerated() {
            guard var app = groups[identifier] else { continue }
            app.windowVisibility = visibilities?[index] ?? .unknown
            groups[identifier] = app
        }
    }

    private func estimatedSavedCPU(for identifier: String) -> Double {
        if let baseline = pausedBaselineCPU[identifier], statuses[identifier] == .paused {
            return baseline
        }
        guard let runtime = limitRuntimes[identifier],
              case .limited = statuses[identifier],
              let currentCPU = groups[identifier]?.cpuPercent else {
            return 0
        }
        return max(0, runtime.estimatedFullSpeedCPU - currentCPU)
    }

    private func snapshot() -> ProcessControlSnapshot {
        ProcessControlSnapshot(
            revision: revision,
            statuses: statuses,
            estimatedSavedCPUByIdentifier: Dictionary(uniqueKeysWithValues: groups.keys.map {
                ($0, estimatedSavedCPU(for: $0))
            }),
            scheduledTickInterval: scheduledTickInterval
        )
    }

}
