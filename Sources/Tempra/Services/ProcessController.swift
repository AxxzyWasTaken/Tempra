import AppKit
import Dispatch
import Foundation
import TempraSafety

private final class ProcessControlSerialExecutor: SerialExecutor {
    private let queue = DispatchQueue(
        label: "com.tempra.process-control",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )

    func enqueue(_ job: UnownedJob) {
        queue.async { [self] in
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }
}

private final class ProcessControlWakeRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var wake: ProcessControlScheduledWake?
    private var isCancelled = false

    func install(_ wake: ProcessControlScheduledWake) {
        let shouldCancel = withLock {
            guard !isCancelled else { return true }
            self.wake = wake
            return false
        }
        if shouldCancel {
            wake.cancel()
        }
    }

    func cancel() {
        let wake = withLock {
            isCancelled = true
            return self.wake
        }
        wake?.cancel()
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

actor ProcessController {
    typealias EventHandler = @MainActor @Sendable (ProcessControllerEvent) -> Void
    typealias FrontmostProvider = @MainActor @Sendable () -> String?
    typealias ApplicationAction = @MainActor @Sendable (String) -> Bool
    typealias AsyncApplicationAction = @MainActor @Sendable (String) async -> Bool
    typealias WindowSnapshotProvider = @Sendable () -> WindowVisibilitySnapshot?

    @TaskLocal private static var reconciliationContext: ProcessReconciliationContext?

    private typealias LimitPhase = ProcessLimitSchedulerModel.Phase
    private typealias LimitRuntime = ProcessLimitSchedulerModel.Runtime
    private typealias LimitDeadline = ProcessLimitSchedulerModel.Deadline
    private typealias LimitDeadlineQueue = ProcessLimitSchedulerModel.DeadlineQueue
    private typealias LimitPulseArbiter = ProcessLimitSchedulerModel.PulseArbiter

    nonisolated private let serialExecutor = ProcessControlSerialExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        serialExecutor.asUnownedSerialExecutor()
    }

    private struct CriticalFileActivityCacheEntry: Sendable {
        let activity: ProcessCriticalFileActivity
        let expiresAt: ContinuousClock.Instant
    }

    private struct AutomaticResumeChange: Sendable {
        let previousIntervals: [ProcessIdentity: TimeInterval]
        let addedProcesses: Set<ProcessIdentity>

        static let empty = AutomaticResumeChange(
            previousIntervals: [:],
            addedProcesses: []
        )
    }

    private struct ProcessRetryResult {
        let unresolved: Set<ProcessIdentity>
        let failureDescription: String?
    }

    private let system: any ProcessSystemControlling
    private let crashWatchdog: any ProcessCrashWatchdogControlling
    private let frontmostProvider: FrontmostProvider
    private let activateApplication: ApplicationAction
    private let hideApplication: ApplicationAction
    private let gracefulTerminateApplication: ApplicationAction
    private let relaunchApplication: AsyncApplicationAction
    private let windowSnapshotProvider: WindowSnapshotProvider
    private let controlInterval: TimeInterval
    private let minimumRunDuration: TimeInterval
    private let clock: ProcessControlClock
    private let signalTelemetry: ProcessControlSignalTelemetry
    private let failureRetryInterval: TimeInterval = 1
    private let criticalFileActivityProbeInterval: TimeInterval = 2
    private let networkSensitivityReleaseDelay: TimeInterval = 5
    private let frontmostProbeInterval: TimeInterval = 1
    private let userActivationProbeDuration: TimeInterval = 0.4
    private let foregroundActivationProtectionDuration: TimeInterval = 1
    private let audioProtectionReleaseDelay: TimeInterval = 15
    private let restorationAttempts = 3
    private let visibilityRecheckInterval: TimeInterval = 1
    static let launchGracePeriod: TimeInterval = 60

    private var eventHandler: EventHandler?
    private var groups: [String: ProcessControlTarget] = [:]
    private var rules: [String: AppRule] = [:]
    private var backgroundSince: [String: Date] = [:]
    private var stoppedByTempra: [String: Set<ProcessIdentity>] = [:]
    private var loweredByTempra: [String: Set<ProcessIdentity>] = [:]
    private var limitPulseLoweredProcesses: [String: Set<ProcessIdentity>] = [:]
    private var limitPriorityProcesses: [String: Set<ProcessIdentity>] = [:]
    private var resumeRestorationFailureDescriptions: [String: String] = [:]
    private var priorityRestorationFailureDescriptions: [String: String] = [:]
    private var limitRuntimes: [String: LimitRuntime] = [:]
    private var limitSelections: [String: ProcessLimitSelection] = [:]
    private var pausedBaselineCPU: [String: Double] = [:]
    private var pauseActivationProbeUntil: [String: Date] = [:]
    private var foregroundActivationProtectionUntil: [String: ContinuousClock.Instant] = [:]
    private var foregroundActivationMinimumRevision: [String: UInt64] = [:]
    private var cachedFrontmostIdentifier: String?
    private var lastFrontmostProbeAt: ContinuousClock.Instant?
    private var networkSensitiveProcesses: [String: Set<ProcessIdentity>] = [:]
    private var networkSensitiveUntil: [String: [ProcessIdentity: ContinuousClock.Instant]] = [:]
    private var downloadProtectedProcesses: [String: Set<ProcessIdentity>] = [:]
    private var criticalFileActivityCache: [ProcessIdentity: CriticalFileActivityCacheEntry] = [:]
    private var automaticResumeIntervals: [ProcessIdentity: TimeInterval] = [:]
    private var automaticResumeStopOperations: [UUID: Set<ProcessIdentity>] = [:]
    private var crashWatchdogIsArmed = false
    private var signalStoppedAt: [ProcessIdentity: ContinuousClock.Instant] = [:]
    private var audioProtection = AudioProtectionTracker()
    private var hideRequested: Set<String> = []
    private var quitRequested: Set<String> = []
    private var statuses: [String: ManagementStatus] = [:]
    private var isEnabled = true
    private var isSystemTransitionSuspended = false
    private var revision: UInt64 = 0
    private var stateID = UUID()
    private var isDrainingReconciliationQueue = false
    private var needsStateReconciliation = false
    private var needsCadenceTick = false
    private var pendingLimitSchedulerGeneration: UInt64?
    private var reconciliationWaiters: [CheckedContinuation<Void, Never>] = []
    private var tickTask: Task<Void, Never>?
    private var limitDeadlines = LimitDeadlineQueue()
    private var limitPulseArbiter = LimitPulseArbiter()
    private var limitSchedulerTask: Task<Void, Never>?
    private var scheduledLimitDeadline: ContinuousClock.Instant?
    private var limitSchedulerGeneration: UInt64 = 0
    private var scheduledTickInterval: TimeInterval?
    private var scheduledTickDeadline: ContinuousClock.Instant?
    private var isPauseWakeMonitoringEnabled = false

    private var managementIsActive: Bool {
        isEnabled && !isSystemTransitionSuspended
    }

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
        gracefulTerminateApplication: @escaping ApplicationAction = { identifier in
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: identifier
            )
            return !applications.isEmpty && applications.allSatisfy { $0.terminate() }
        },
        relaunchApplication: @escaping AsyncApplicationAction = { identifier in
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: identifier
            )
            guard !applications.isEmpty,
                  let applicationURL = applications.compactMap(\.bundleURL).first
                    ?? NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: identifier
                    ),
                  applications.allSatisfy({ $0.terminate() }) else {
                return false
            }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while applications.contains(where: { !$0.isTerminated }), clock.now < deadline {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return false
                }
            }
            guard applications.allSatisfy(\.isTerminated) else { return false }

            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { application, error in
                    continuation.resume(returning: application != nil && error == nil)
                }
            }
        },
        windowSnapshotProvider: @escaping WindowSnapshotProvider = {
            WindowVisibilitySnapshot.capture()
        },
        controlInterval: TimeInterval = 0.5,
        minimumRunDuration: TimeInterval = 0.005,
        clock: ProcessControlClock = .continuous,
        signalTelemetry: ProcessControlSignalTelemetry = ProcessControlSignalTelemetry()
    ) {
        self.system = system
        self.crashWatchdog = crashWatchdog
        self.frontmostProvider = frontmostProvider
        self.activateApplication = activateApplication
        self.hideApplication = hideApplication
        self.gracefulTerminateApplication = gracefulTerminateApplication
        self.relaunchApplication = relaunchApplication
        self.windowSnapshotProvider = windowSnapshotProvider
        self.controlInterval = controlInterval
        self.minimumRunDuration = minimumRunDuration
        self.clock = clock
        self.signalTelemetry = signalTelemetry
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

        let changedRuleIdentifiers = Set(previousRules.keys).union(self.rules.keys).filter { identifier in
            guard let previous = previousRules[identifier],
                  let current = self.rules[identifier] else {
                return true
            }
            return !previous.hasSameLimiterConfiguration(as: current)
        }
        for identifier in changedRuleIdentifiers {
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            limitSelections.removeValue(forKey: identifier)
            networkSensitiveProcesses.removeValue(forKey: identifier)
            networkSensitiveUntil.removeValue(forKey: identifier)
            downloadProtectedProcesses.removeValue(forKey: identifier)
            limitPulseArbiter.release(identifier: identifier)
        }
        if !managementIsActive {
            networkSensitiveProcesses.removeAll()
            networkSensitiveUntil.removeAll()
            downloadProtectedProcesses.removeAll()
            criticalFileActivityCache.removeAll()
            limitPulseArbiter.removeAll()
        }
        refreshNetworkSensitivity()

        needsStateReconciliation = true
        await drainReconciliationQueue()
        return snapshot()
    }

    func updateMeasurements(
        targets: [ProcessControlTarget]
    ) -> ProcessControlSnapshot {
        let incomingGroups = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.bundleIdentifier, $0) }
        )
        guard Set(incomingGroups.keys) == Set(groups.keys),
              incomingGroups.allSatisfy({ identifier, target in
                  groups[identifier]?.processIdentities == target.processIdentities
              }) else {
            return snapshot()
        }

        for (identifier, target) in incomingGroups {
            guard let current = groups[identifier] else { continue }
            var updated = target
            updated.windowVisibility = current.windowVisibility
            groups[identifier] = updated
        }
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
        if managementIsActive {
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

    func suspendForSystemTransition() async -> ProcessControlSnapshot {
        stateID = UUID()
        isSystemTransitionSuspended = true
        needsStateReconciliation = true
        await drainReconciliationQueue()
        return snapshot()
    }

    func resumeAfterSystemTransition() async -> ProcessControlSnapshot {
        guard isSystemTransitionSuspended else { return snapshot() }
        stateID = UUID()
        isSystemTransitionSuspended = false
        backgroundSince.removeAll(keepingCapacity: true)
        needsStateReconciliation = true
        await drainReconciliationQueue()
        return snapshot()
    }

    func applicationDidActivate(
        bundleIdentifier: String
    ) async -> ProcessControlSnapshot {
        cachedFrontmostIdentifier = bundleIdentifier
        lastFrontmostProbeAt = clock.now()
        let isManaged = rules[bundleIdentifier]?.hasBehavior == true
            || stoppedByTempra[bundleIdentifier]?.isEmpty == false
            || loweredByTempra[bundleIdentifier]?.isEmpty == false
            || limitRuntimes[bundleIdentifier] != nil
        guard isManaged else { return snapshot() }

        foregroundActivationMinimumRevision[bundleIdentifier] = revision == .max
            ? .max
            : revision + 1
        foregroundActivationProtectionUntil[bundleIdentifier] = clock.now().advanced(
            by: ProcessControlMath.duration(foregroundActivationProtectionDuration)
        )

        let activationStartedAt = clock.now()
        let restored = await restore(
            identifier: bundleIdentifier,
            resetDelay: true,
            attempts: restorationAttempts,
            resumeReason: .applicationActivation
        )
        let activationDuration = max(
            0,
            ProcessControlMath.timeInterval(activationStartedAt.duration(to: clock.now()))
        )
        await signalTelemetry.recordMeasurement(ProcessLimitMeasurement(
            date: Date(),
            bundleIdentifier: bundleIdentifier,
            kind: .activation,
            requestedLimitPercent: rules[bundleIdentifier]?.limitPercent,
            measuredCPUPercent: nil,
            cpuDeltaNanoseconds: nil,
            wallDuration: activationDuration,
            deadlineLateness: nil,
            activePulseCount: limitPulseArbiter.activeCount,
            serviceGap: nil
        ))

        if restored {
            await setStatus(.normal, for: bundleIdentifier)
        } else {
            await markUnavailable(
                bundleIdentifier,
                detail: "Tempra could not restore every process after the app became active."
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
        case .quitGracefully:
            if groups[bundleIdentifier]?.usesApplicationCommands == true {
                await gracefulTerminateApplication(bundleIdentifier)
            } else { false }
        case .quit:
            if let group = groups[bundleIdentifier] {
                await requestTermination(for: group)
            } else { false }
        case .relaunch:
            if groups[bundleIdentifier]?.usesApplicationCommands == true {
                await relaunchApplication(bundleIdentifier)
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
        case .quit, .quitGracefully:
            quitRequested.insert(bundleIdentifier)
            await setStatus(.waiting, for: bundleIdentifier)
            await emitActivity(
                bundleIdentifier,
                kind: command == .quit ? .quit : .gracefulQuit,
                detail: command == .quit
                    ? "Force quit from the process menu"
                    : "Quit request from the process menu"
            )
        case .relaunch:
            await setStatus(.normal, for: bundleIdentifier)
            await emitActivity(
                bundleIdentifier,
                kind: .relaunched,
                detail: "Relaunched from the process menu"
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
            automaticResumeIntervals.removeAll()
            if crashWatchdogIsArmed {
                crashWatchdogIsArmed = false
                await crashWatchdog.disarm()
            }
        }
        return result
    }

    func wakePausedApplicationsForUserActivation() async {
        guard managementIsActive else { return }
        let until = Date().addingTimeInterval(userActivationProbeDuration)
        for identifier in Array(stoppedByTempra.keys) where rules[identifier]?.action == .pause {
            let stopped = stoppedByTempra[identifier, default: []]
            let result = await resumeProcesses(
                stopped,
                identifier: identifier,
                reason: .userActivationProbe
            )
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

    func currentRestorationResult() -> ProcessRestorationResult {
        restorationResult()
    }

    func recentSignalEvents() async -> [ProcessControlSignalEvent] {
        await signalTelemetry.snapshot()
    }

    func recentLimitMeasurements() async -> [ProcessLimitMeasurement] {
        await signalTelemetry.measurementSnapshot()
    }

    func recentLimitTelemetrySummary(
        since date: Date
    ) async -> ProcessLimitTelemetrySummary {
        await signalTelemetry.summary(since: date)
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
            .union(loweredByTempra.keys)
            .union(limitPriorityProcesses.keys)
            .union(limitRuntimes.keys)
            .union(pausedBaselineCPU.keys)
            .union(pauseActivationProbeUntil.keys)
    }

    private func refreshNetworkSensitivity() {
        guard managementIsActive else { return }
        let now = clock.now()
        let trackedNetworkIdentifiers = Set(networkSensitiveProcesses.keys)
            .union(networkSensitiveUntil.keys)
        for identifier in trackedNetworkIdentifiers {
            guard rules[identifier]?.action == .limit,
                  let currentProcesses = groups[identifier]?.processIdentities else {
                networkSensitiveProcesses.removeValue(forKey: identifier)
                networkSensitiveUntil.removeValue(forKey: identifier)
                continue
            }
            var deadlines = networkSensitiveUntil[identifier, default: [:]].filter {
                currentProcesses.contains($0.key) && $0.value > now
            }
            for sample in groups[identifier]?.processSamples ?? [] {
                if sample.networkActivity == .active {
                    deadlines[sample.identity] = now.advanced(
                        by: ProcessControlMath.duration(networkSensitivityReleaseDelay)
                    )
                }
            }
            let retainedSensitive = Set(deadlines.keys)
            if retainedSensitive.isEmpty {
                networkSensitiveProcesses.removeValue(forKey: identifier)
                networkSensitiveUntil.removeValue(forKey: identifier)
            } else {
                networkSensitiveProcesses[identifier] = retainedSensitive
                networkSensitiveUntil[identifier] = deadlines
            }
        }

        for (identifier, app) in groups where rules[identifier]?.action == .limit {
            let activeProcesses = Set(app.processSamples.compactMap { sample in
                sample.networkActivity == .active ? sample.identity : nil
            })
            guard !activeProcesses.isEmpty else { continue }
            markNetworkSensitive(activeProcesses, for: identifier, now: now)
        }

        for identifier in Array(foregroundActivationMinimumRevision.keys)
            where groups[identifier] == nil || rules[identifier]?.hasBehavior != true {
            foregroundActivationMinimumRevision.removeValue(forKey: identifier)
            foregroundActivationProtectionUntil.removeValue(forKey: identifier)
        }
    }

    private func markNetworkSensitive(
        _ processes: Set<ProcessIdentity>,
        for identifier: String,
        now: ContinuousClock.Instant? = nil
    ) {
        guard !processes.isEmpty else { return }
        let expiresAt = (now ?? clock.now()).advanced(
            by: ProcessControlMath.duration(networkSensitivityReleaseDelay)
        )
        networkSensitiveProcesses[identifier, default: []].formUnion(processes)
        for process in processes {
            networkSensitiveUntil[identifier, default: [:]][process] = expiresAt
        }
    }

    private func latencySensitiveProcesses(
        for app: ProcessControlTarget
    ) -> Set<ProcessIdentity> {
        var processes = networkSensitiveProcesses[app.bundleIdentifier, default: []]
        processes.formUnion(app.processSamples.compactMap { sample in
            sample.networkActivity.isLatencySensitive ? sample.identity : nil
        })
        return processes.intersection(app.processIdentities)
    }

    private func scheduledAutomaticResumeInterval(
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

    private func refreshCriticalFileProtection() async {
        let currentProcesses = groups.values.reduce(into: Set<ProcessIdentity>()) {
            $0.formUnion($1.processIdentities)
        }
        criticalFileActivityCache = criticalFileActivityCache.filter {
            currentProcesses.contains($0.key)
        }

        for identifier in Array(downloadProtectedProcesses.keys).sorted() {
            guard workIsCurrent else { return }
            guard rules[identifier]?.action == .limit,
                  let app = groups[identifier] else {
                downloadProtectedProcesses.removeValue(forKey: identifier)
                continue
            }
            var protected = downloadProtectedProcesses[identifier, default: []]
                .intersection(app.processIdentities)
            for process in protected.sorted(by: { $0.pid < $1.pid }) {
                let activity = await criticalFileActivity(for: process)
                guard workIsCurrent else { return }
                if activity == .inactive {
                    protected.remove(process)
                }
            }
            if protected.isEmpty {
                downloadProtectedProcesses.removeValue(forKey: identifier)
            } else {
                downloadProtectedProcesses[identifier] = protected
            }
        }
    }

    private func criticalFileActivity(
        for process: ProcessIdentity
    ) async -> ProcessCriticalFileActivity {
        let now = clock.now()
        if let cached = criticalFileActivityCache[process], cached.expiresAt > now {
            return cached.activity
        }
        let activity = await system.criticalFileActivity(for: process)
        guard workIsCurrent else { return .unknown }
        criticalFileActivityCache[process] = CriticalFileActivityCacheEntry(
            activity: activity,
            expiresAt: clock.now().advanced(
                by: ProcessControlMath.duration(criticalFileActivityProbeInterval)
            )
        )
        return activity
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

    private func tick(trigger: ProcessControlTickTrigger) async {
        if trigger == .cadence {
            tickTask = nil
            scheduledTickInterval = nil
            scheduledTickDeadline = nil
        }
        guard workIsCurrent, managementIsActive else {
            await updatePauseWakeMonitoring()
            return
        }
        let now = Date()
        refreshNetworkSensitivity()
        if trigger == .cadence {
            refreshWindowVisibility()
            await refreshCriticalFileProtection()
            guard workIsCurrent else { return }
        }

        for (identifier, rule) in rules where rule.hasBehavior {
            guard workIsCurrent else { return }
            guard let app = groups[identifier] else { continue }

            if quitRequested.contains(identifier), statuses[identifier] != .unavailable {
                await setStatus(.waiting, for: identifier)
                continue
            }

            var isAudioProtected = audioProtection.update(
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

            if rule.protectAudio, !isAudioProtected {
                let liveAudioActivity = await system.audioActivity(
                    for: app.processIdentities
                )
                guard workIsCurrent else { return }
                switch liveAudioActivity {
                case .active:
                    isAudioProtected = audioProtection.update(
                        identifier: identifier,
                        isPlayingAudio: true,
                        protectsAudio: true,
                        now: clock.now(),
                        releaseDelay: ProcessControlMath.duration(
                            audioProtectionReleaseDelay
                        )
                    )
                case .unknown:
                    isAudioProtected = true
                case .inactive:
                    break
                }
            }

            let isWithinLaunchGrace = app.launchedAt.map {
                now < $0.addingTimeInterval(Self.launchGracePeriod)
            } ?? false

            if app.isProtectedByForegroundOverlay {
                backgroundSince.removeValue(forKey: identifier)
                hideRequested.remove(identifier)
                quitRequested.remove(identifier)
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesLowerPriority: !isWithinLaunchGrace
                ) {
                    guard workIsCurrent else { return }
                    await setStatus(
                        isWithinLaunchGrace
                            ? .waiting
                            : (rule.usesLowerCPUPriority ? .lowerPriority : .normal),
                        for: identifier
                    )
                }
                continue
            }

            if isAudioProtected {
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesLowerPriority: false
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
                    appliesLowerPriority: false
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

            if rule.action != .limit,
               (rule.action != .none || rule.lowersCPUPriority),
               app.windowVisibility.protectsFromDisruptiveManagement {
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesLowerPriority: false
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
                    appliesLowerPriority: false
                ) {
                    guard workIsCurrent else { return }
                    backgroundSince[identifier] = backgroundStart
                    await setStatus(.waiting, for: identifier)
                }
                continue
            }

            let visibilityDelay = rule.action == .limit
                ? 0
                : app.windowVisibility.minimumDisruptiveDelay
            let startDelay = max(rule.delaySeconds, visibilityDelay)
            if rule.action != .none, backgroundDuration < startDelay {
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesLowerPriority: true
                ) {
                    guard workIsCurrent else { return }
                    backgroundSince[identifier] = backgroundStart
                    await setStatus(
                        rule.usesLowerCPUPriority ? .lowerPriority : .waiting,
                        for: identifier
                    )
                }
                continue
            }

            if (rule.action != .none || rule.lowersCPUPriority),
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
            let priorityPrepared: Bool
            if rule.usesLowerCPUPriority {
                priorityPrepared = await applyLowerPriority(to: app)
            } else {
                priorityPrepared = await restoreLowerPriority(
                    for: identifier,
                    attempts: restorationAttempts
                )
            }
            guard workIsCurrent else { return }
            let resumed = await resumeStoppedProcesses(
                for: identifier,
                attempts: restorationAttempts
            )
            guard resumed else {
                await markUnavailable(identifier, detail: "Tempra could not resume every process.")
                return
            }
            guard workIsCurrent else { return }
            guard priorityPrepared else {
                if rule.usesLowerCPUPriority { return }
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore normal process priority."
                )
                return
            }
            await setStatus(
                rule.usesLowerCPUPriority ? .lowerPriority : .normal,
                for: identifier
            )
        case .pause:
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            guard await restoreLowerPriority(
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
            if rule.usesLowerCPUPriority {
                guard await applyLowerPriority(to: app) else { return }
            } else {
                guard await restoreLowerPriority(
                    for: identifier,
                    attempts: restorationAttempts
                ) else {
                    await markUnavailable(
                        identifier,
                        detail: "Tempra could not restore normal process priority before limiting CPU."
                    )
                    return
                }
            }
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
        let result = await stopProcesses(
            processesToStop,
            identifier: identifier,
            reason: .backgroundPause
        )
        if !workIsCurrent {
            let stopped = existing.union(result.applied)
            _ = await setStoppedProcesses(stopped, for: identifier)
            return false
        }
        guard result.failed.isEmpty else {
            let rollback = await resumeProcesses(
                existing.union(result.applied),
                identifier: identifier,
                reason: .stopRollback
            )
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

    private func applyLowerPriority(to app: ProcessControlTarget) async -> Bool {
        guard workIsCurrent else { return false }
        let identifier = app.bundleIdentifier
        var existing = loweredByTempra[identifier, default: []]
            .intersection(app.processIdentities)
        var protectedProcesses = latencySensitiveProcesses(for: app)
        protectedProcesses.formUnion(
            downloadProtectedProcesses[identifier, default: []]
        )
        protectedProcesses.formUnion(app.processSamples.compactMap { sample in
            sample.isPlayingAudio ? sample.identity : nil
        })
        let desired = app.processIdentities.subtracting(protectedProcesses)

        let noLongerDesired = existing.subtracting(desired)
        if !noLongerDesired.isEmpty {
            let restoreResult = await system.restorePriority(noLongerDesired)
            existing.subtract(restoreResult.applied.union(restoreResult.stale))
            guard workIsCurrent else {
                loweredByTempra[identifier] = existing
                return false
            }
            guard restoreResult.failed.isEmpty else {
                loweredByTempra[identifier] = existing.union(restoreResult.failed)
                await markUnavailable(
                    identifier,
                    detail: restoreResult.failureDescription
                        ?? "Tempra could not restore network or critical-activity processes to normal priority."
                )
                return false
            }
        }

        let result = await system.lowerPriority(
            desired.subtracting(existing)
        )
        if !workIsCurrent {
            loweredByTempra[identifier] = existing.union(result.applied)
            return false
        }
        guard result.failed.isEmpty else {
            let rollback = await system.restorePriority(existing.union(result.applied))
            loweredByTempra[identifier] = rollback.failed
            await markUnavailable(
                identifier,
                detail: result.failureDescription
                    ?? "Tempra could not lower the priority of every process."
            )
            return false
        }

        let backgrounded = existing.union(result.applied).intersection(desired)
        if backgrounded.isEmpty {
            loweredByTempra.removeValue(forKey: identifier)
        } else {
            loweredByTempra[identifier] = backgrounded
        }
        return true
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

    private func restoreLimitPulsePriority(
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
        let normalResult = normalPriorityProcesses.isEmpty
            ? ProcessOperationResult()
            : await system.restorePriority(normalPriorityProcesses)

        loweredByTempra[identifier, default: []].formUnion(lowerResult.applied)
        loweredByTempra[identifier]?.subtract(
            normalResult.applied.union(normalResult.stale)
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

    private func runLimitCycle(
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
                await setStatus(.normal, for: identifier)
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
            await setStatus(selection.targetIsReachable ? .normal : .waiting, for: identifier)
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
                    : .normal,
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
        let measuredCPU: Double
        if let existingRuntime, existingRuntime.runStartedAt == nil {
            measuredCPU = existingRuntime.lastMeasuredCPUPercent
                ?? selection.controlledCPUPercent
        } else if let existingRuntime {
            let elapsed = max(
                0,
                ProcessControlMath.timeInterval(
                    existingRuntime.lastAccountingAt.duration(to: now)
                )
            )
            if elapsed > 0, nowCPU >= existingRuntime.lastCPUNanoseconds {
                measuredCPU = Double(nowCPU - existingRuntime.lastCPUNanoseconds)
                    / (elapsed * 1_000_000_000)
                    * 100
            } else {
                measuredCPU = selection.controlledCPUPercent
            }
        } else {
            measuredCPU = selection.controlledCPUPercent
        }
        let usage = ProcessControlMath.normalizedCPUPercent(measuredCPU)
        let previousDutyFactor = existingRuntime?.dutyFactor ?? 0
        let controlPeriod = ProcessControlMath.controlPeriod(
            usage: usage,
            previousDutyFactor: previousDutyFactor
        )
        let startsAboveLimit = usage > limitPercent
        let hasActivatedLimit = existingRuntime?.hasActivatedLimit == true
            || startsAboveLimit
        let estimatedFullSpeedCPU = max(
            existingRuntime?.estimatedFullSpeedCPU ?? 0,
            usage,
            limitPercent,
            1
        )
        let dutyFactor = hasActivatedLimit
            ? ProcessControlMath.requiredDutyFactor(
                estimatedFullSpeedCPU: estimatedFullSpeedCPU,
                limitPercent: limitPercent
            )
            : 0

        var runtime = existingRuntime ?? LimitRuntime(
            lastCPUNanoseconds: nowCPU,
            lastAccountingAt: now,
            runStartedAt: now,
            estimatedFullSpeedCPU: max(usage, limitPercent, 1),
            lastMeasuredCPUPercent: usage,
            dutyFactor: dutyFactor,
            hasActivatedLimit: hasActivatedLimit,
            scheduledStopDuration: dutyFactor,
            stoppedAt: nil,
            generation: 0,
            phase: hasActivatedLimit ? .running : .observing,
            processIdentities: controlledProcesses
        )
        runtime.lastCPUNanoseconds = nowCPU
        runtime.lastAccountingAt = now
        runtime.runStartedAt = now
        runtime.estimatedFullSpeedCPU = estimatedFullSpeedCPU
        runtime.lastMeasuredCPUPercent = usage
        runtime.dutyFactor = dutyFactor
        runtime.hasActivatedLimit = hasActivatedLimit
        runtime.scheduledStopDuration = dutyFactor
        runtime.stoppedAt = nil
        runtime.generation = ProcessControlMath.nextGeneration(after: runtime.generation)
        runtime.phase = hasActivatedLimit ? .running : .observing
        runtime.processIdentities = controlledProcesses
        let generation = runtime.generation
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
            await setStatus(.normal, for: identifier)
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
            processIdentities: runtime.processIdentities,
            kind: .evaluate
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

    private func stopProcesses(
        _ processes: Set<ProcessIdentity>,
        identifier: String,
        reason: ProcessControlSignalReason
    ) async -> ProcessOperationResult {
        guard !processes.isEmpty else { return ProcessOperationResult() }
        let automaticResumeOperationID: UUID?
        if reason == .cpuLimitPulse {
            let operationID = UUID()
            automaticResumeStopOperations[operationID] = processes
            automaticResumeOperationID = operationID
        } else {
            automaticResumeOperationID = nil
        }
        let automaticResumeAfter = reason == .cpuLimitPulse
            ? scheduledAutomaticResumeInterval(for: identifier, processes: processes)
            : nil
        let result = await system.stop(
            processes,
            automaticResumeAfter: automaticResumeAfter
        )
        if reason == .cpuLimitPulse {
            if let automaticResumeOperationID {
                automaticResumeStopOperations.removeValue(forKey: automaticResumeOperationID)
            }
            if let automaticResumeAfter {
                for process in result.applied where !process.requiresPrivilegedControl {
                    automaticResumeIntervals[process] = automaticResumeAfter
                }
            }
            let stillPending = automaticResumeStopOperations.values.reduce(
                into: Set<ProcessIdentity>()
            ) { pending, operationProcesses in
                pending.formUnion(operationProcesses)
            }
            for process in result.failed.union(result.stale).subtracting(stillPending) {
                automaticResumeIntervals.removeValue(forKey: process)
            }
        }
        let stoppedAt = clock.now()
        for process in result.applied where signalStoppedAt[process] == nil {
            signalStoppedAt[process] = stoppedAt
        }
        await signalTelemetry.record(ProcessControlSignalEvent(
            date: Date(),
            bundleIdentifier: identifier,
            operation: .stop,
            reason: reason,
            requested: processes,
            result: result,
            stoppedDurations: [:]
        ))
        return result
    }

    private func resumeProcesses(
        _ processes: Set<ProcessIdentity>,
        identifier: String?,
        reason: ProcessControlSignalReason,
        retainingAutomaticResume retainedProcesses: Set<ProcessIdentity> = []
    ) async -> ProcessOperationResult {
        guard !processes.isEmpty else { return ProcessOperationResult() }
        let result = await system.resume(processes)
        let stillPending = automaticResumeStopOperations.values.reduce(
            into: Set<ProcessIdentity>()
        ) { pending, operationProcesses in
            pending.formUnion(operationProcesses)
        }
        for process in result.applied
            .union(result.stale)
            .subtracting(stillPending)
            .subtracting(retainedProcesses) {
            automaticResumeIntervals.removeValue(forKey: process)
        }
        let resumedAt = clock.now()
        var durations: [ProcessIdentity: TimeInterval] = [:]
        for process in result.applied.union(result.stale) {
            if let stoppedAt = signalStoppedAt.removeValue(forKey: process) {
                durations[process] = max(
                    0,
                    ProcessControlMath.timeInterval(stoppedAt.duration(to: resumedAt))
                )
            }
        }
        await signalTelemetry.record(ProcessControlSignalEvent(
            date: Date(),
            bundleIdentifier: identifier,
            operation: .resume,
            reason: reason,
            requested: processes,
            result: result,
            stoppedDurations: durations
        ))
        if let identifier, let maximumGap = durations.values.max() {
            await signalTelemetry.recordMeasurement(ProcessLimitMeasurement(
                date: Date(),
                bundleIdentifier: identifier,
                kind: .serviceGap,
                requestedLimitPercent: rules[identifier]?.limitPercent,
                measuredCPUPercent: nil,
                cpuDeltaNanoseconds: nil,
                wallDuration: nil,
                deadlineLateness: nil,
                activePulseCount: limitPulseArbiter.activeCount,
                serviceGap: maximumGap
            ))
        }
        return result
    }

    private func recordPreventedStop(
        _ processes: Set<ProcessIdentity>,
        identifier: String,
        reason: ProcessControlSignalReason
    ) async {
        await signalTelemetry.record(ProcessControlSignalEvent(
            date: Date(),
            bundleIdentifier: identifier,
            operation: .stopPrevented,
            reason: reason,
            requested: processes,
            result: ProcessOperationResult(),
            stoppedDurations: [:]
        ))
    }

    private func maintainLimitCycle(
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
        guard managementIsActive,
              let currentApp = groups[identifier],
              processIdentities.isSubset(of: currentApp.processIdentities),
              rules[identifier]?.action == .limit else {
            return
        }
        await runLimitCycle(for: currentApp, limitPercent: limitPercent)
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

    private func reconcileControlledProcesses() async {
        guard workIsCurrent else { return }
        for identifier in Set(stoppedByTempra.keys)
            .union(loweredByTempra.keys)
            .union(limitPriorityProcesses.keys) {
            guard workIsCurrent else { return }
            let current = groups[identifier]?.processIdentities ?? []

            let retiredStopped = stoppedByTempra[identifier, default: []].subtracting(current)
            if !retiredStopped.isEmpty {
                let result = await resumeProcesses(
                    retiredStopped,
                    identifier: identifier,
                    reason: .processReconciliation
                )
                let remaining = stoppedByTempra[identifier, default: []]
                    .subtracting(result.applied.union(result.stale))
                _ = await setStoppedProcesses(remaining, for: identifier)
                guard workIsCurrent else { return }
            }

            let retiredLimitPriority = limitPriorityProcesses[identifier, default: []]
                .subtracting(current)
            if !retiredLimitPriority.isEmpty {
                _ = await restoreLimitPulsePriority(
                    for: identifier,
                    processes: retiredLimitPriority
                )
                guard workIsCurrent else { return }
            }

            let retiredBackgrounded = loweredByTempra[identifier, default: []]
                .subtracting(current)
            if !retiredBackgrounded.isEmpty {
                let result = await system.restorePriority(retiredBackgrounded)
                loweredByTempra[identifier]?.subtract(result.applied.union(result.stale))
                guard workIsCurrent else { return }
            }
        }
        await updatePauseWakeMonitoring()
    }

    private func restore(
        identifier: String,
        resetDelay: Bool,
        attempts: Int,
        resumeReason: ProcessControlSignalReason = .restoration
    ) async -> Bool {
        let priorityRestored = await restoreNormalPriority(
            for: identifier,
            attempts: attempts
        )
        guard workIsCurrent else { return false }
        let resumed = await restoreDisruptiveControl(
            identifier: identifier,
            attempts: attempts,
            resumeReason: resumeReason,
            retainingLimitPriority: true
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
        let priorityRestored = await restoreNormalPriority(
            for: identifier,
            attempts: attempts
        )
        guard workIsCurrent else { return false }
        let resumed = await restoreDisruptiveControl(
            identifier: identifier,
            attempts: attempts,
            retainingLimitPriority: true
        )
        return resumed && priorityRestored && workIsCurrent
    }

    private func restoreDisruptiveControl(
        identifier: String,
        attempts: Int,
        resumeReason: ProcessControlSignalReason = .restoration,
        retainingLimitPriority: Bool = false
    ) async -> Bool {
        guard workIsCurrent else { return false }
        limitPulseArbiter.release(identifier: identifier)
        limitDeadlines.remove(identifier: identifier)
        limitRuntimes.removeValue(forKey: identifier)
        pausedBaselineCPU.removeValue(forKey: identifier)
        pauseActivationProbeUntil.removeValue(forKey: identifier)
        return await resumeStoppedProcesses(
            for: identifier,
            attempts: attempts,
            reason: resumeReason,
            retainingLimitPriority: retainingLimitPriority
        )
    }

    private func prepareForDeferredAction(
        rule: AppRule,
        app: ProcessControlTarget,
        appliesLowerPriority: Bool
    ) async -> Bool {
        guard workIsCurrent else { return false }
        let identifier = app.bundleIdentifier
        let priorityPrepared: Bool
        let retainingLimitPriority: Bool
        if appliesLowerPriority, rule.usesLowerCPUPriority {
            priorityPrepared = await applyLowerPriority(to: app)
            retainingLimitPriority = false
        } else {
            priorityPrepared = await restoreNormalPriority(
                for: identifier,
                attempts: restorationAttempts
            )
            retainingLimitPriority = true
            if !priorityPrepared {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore normal process priority."
                )
            }
        }
        guard workIsCurrent else { return false }

        let resumed = await restoreDisruptiveControl(
            identifier: identifier,
            attempts: restorationAttempts,
            retainingLimitPriority: retainingLimitPriority
        )
        guard resumed else {
            await markUnavailable(identifier, detail: "Tempra could not restore every process.")
            return false
        }
        guard workIsCurrent else { return false }
        return priorityPrepared
    }

    private func resumeStoppedProcesses(
        for identifier: String,
        attempts: Int,
        reason: ProcessControlSignalReason = .restoration,
        retainingAutomaticResume retainedProcesses: Set<ProcessIdentity> = [],
        retainingLimitPriority: Bool = false
    ) async -> Bool {
        let stoppedProcesses = stoppedByTempra[identifier, default: []]
        let priorityRestored: Bool
        if !retainingLimitPriority,
           limitPriorityProcesses[identifier]?.isEmpty == false {
            priorityRestored = await restoreLimitPulsePriority(
                for: identifier,
                processes: limitPriorityProcesses[identifier, default: []]
            )
        } else {
            priorityRestored = true
        }
        let retryResult = await performWithRetries(
            stoppedProcesses,
            attempts: attempts,
            operation: {
                await resumeProcesses(
                    $0,
                    identifier: identifier,
                    reason: reason,
                    retainingAutomaticResume: retainedProcesses
                )
            }
        )
        let unresolved = retryResult.unresolved
        if unresolved.isEmpty {
            resumeRestorationFailureDescriptions.removeValue(forKey: identifier)
        } else {
            resumeRestorationFailureDescriptions[identifier] =
                retryResult.failureDescription ?? "The process resume request failed."
        }
        let synchronized = await setStoppedProcesses(unresolved, for: identifier)
        return priorityRestored
            && unresolved.isEmpty
            && synchronized
            && workIsCurrent
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

    private var allWatchdogProtectedProcesses: Set<ProcessIdentity> {
        limitRuntimes.values.reduce(
            into: Set(allStoppedProcesses.lazy.filter {
                !$0.requiresPrivilegedControl
            }).union(automaticResumeIntervals.keys)
        ) { processes, runtime in
            switch runtime.phase {
            case .running, .stopped:
                processes.formUnion(runtime.processIdentities.lazy.filter {
                    !$0.requiresPrivilegedControl
                })
            case .observing:
                break
            }
        }
    }

    private func prepareWatchdogToStop(
        _ processes: Set<ProcessIdentity>,
        for identifier: String
    ) async -> Bool {
        guard workIsCurrent else { return false }
        let userOwnedProcesses = Set(processes.lazy.filter {
            !$0.requiresPrivilegedControl
        })
        guard !userOwnedProcesses.isEmpty else { return true }
        do {
            try await crashWatchdog.prepareToStop(userOwnedProcesses)
            crashWatchdogIsArmed = true
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

    private func armWatchdogAutomaticResume(
        _ processes: Set<ProcessIdentity>,
        for identifier: String,
        automaticResumeAfter requestedInterval: TimeInterval? = nil
    ) async -> AutomaticResumeChange? {
        guard workIsCurrent, !processes.isEmpty else { return nil }
        let userOwnedProcesses = Set(processes.lazy.filter {
            !$0.requiresPrivilegedControl
        })
        guard !userOwnedProcesses.isEmpty else { return .empty }
        let maximumStopDuration = scheduledAutomaticResumeInterval(
            for: identifier,
            processes: processes
        )
        let proposedInterval = requestedInterval ?? maximumStopDuration
        guard proposedInterval.isFinite, proposedInterval > 0 else {
            await markUnavailable(
                identifier,
                detail: "Tempra could not set a valid automatic-resume deadline."
            )
            return nil
        }
        let interval = max(maximumStopDuration, proposedInterval)
        let processesToArm = Set(userOwnedProcesses.filter {
            automaticResumeIntervals[$0] != interval
        })
        guard !processesToArm.isEmpty else { return .empty }
        let previousIntervals = automaticResumeIntervals.filter {
            processesToArm.contains($0.key)
        }
        let addedProcesses = processesToArm.subtracting(previousIntervals.keys)
        for process in processesToArm {
            automaticResumeIntervals[process] = interval
        }
        let change = AutomaticResumeChange(
            previousIntervals: previousIntervals,
            addedProcesses: addedProcesses
        )
        do {
            try await crashWatchdog.armAutomaticResume(
                Dictionary(uniqueKeysWithValues: processesToArm.map { ($0, interval) })
            )
            guard workIsCurrent else {
                await cancelWatchdogAutomaticResume(change, for: identifier)
                return nil
            }
            return change
        } catch {
            restoreAutomaticResumeIntervals(change)
            await markUnavailable(identifier, detail: error.localizedDescription)
            return nil
        }
    }

    private func cancelWatchdogAutomaticResume(
        _ change: AutomaticResumeChange,
        for identifier: String
    ) async {
        restoreAutomaticResumeIntervals(change)
        do {
            try await crashWatchdog.synchronizeAutomaticResume(
                automaticResumeIntervals
            )
            try await crashWatchdog.synchronize(allWatchdogProtectedProcesses)
        } catch {
            await markUnavailable(identifier, detail: error.localizedDescription)
        }
    }

    private func restoreAutomaticResumeIntervals(
        _ change: AutomaticResumeChange
    ) {
        for process in change.addedProcesses {
            automaticResumeIntervals.removeValue(forKey: process)
        }
        automaticResumeIntervals.merge(
            change.previousIntervals,
            uniquingKeysWith: { _, previousValue in previousValue }
        )
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

        let protectedProcesses = allWatchdogProtectedProcesses
        if protectedProcesses.isEmpty {
            automaticResumeIntervals.removeAll()
            if crashWatchdogIsArmed {
                crashWatchdogIsArmed = false
                await crashWatchdog.disarm()
            }
            return true
        }

        do {
            try await crashWatchdog.synchronize(protectedProcesses)
            try await crashWatchdog.synchronizeAutomaticResume(
                automaticResumeIntervals
            )
            return true
        } catch {
            let pending = allStoppedProcesses
            let emergencyResult = await resumeProcesses(
                pending,
                identifier: nil,
                reason: .emergencyRestoration
            )
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
            backgroundedByIdentifier: loweredByTempra,
            resumeFailureDescriptions: resumeRestorationFailureDescriptions,
            priorityFailureDescriptions: priorityRestorationFailureDescriptions
        )
    }

    private func restoreNormalPriority(
        for identifier: String,
        attempts: Int
    ) async -> Bool {
        let limitPriority = limitPriorityProcesses[identifier, default: []]
        let priorityProcesses = loweredByTempra[identifier, default: []]
            .union(limitPriority)
        let retryResult = await performWithRetries(
            priorityProcesses,
            attempts: attempts,
            operation: { await system.restorePriority($0) }
        )
        let unresolved = retryResult.unresolved
        if unresolved.isEmpty {
            priorityRestorationFailureDescriptions.removeValue(forKey: identifier)
        } else {
            priorityRestorationFailureDescriptions[identifier] =
                retryResult.failureDescription ?? "The process priority restore request failed."
        }

        limitPulseLoweredProcesses.removeValue(forKey: identifier)
        let unresolvedLimitPriority = limitPriority.intersection(unresolved)
        if unresolvedLimitPriority.isEmpty {
            limitPriorityProcesses.removeValue(forKey: identifier)
        } else {
            limitPriorityProcesses[identifier] = unresolvedLimitPriority
        }
        if unresolved.isEmpty {
            loweredByTempra.removeValue(forKey: identifier)
        } else {
            loweredByTempra[identifier] = unresolved
        }
        return unresolved.isEmpty && workIsCurrent
    }

    private func restoreLowerPriority(for identifier: String, attempts: Int) async -> Bool {
        let retryResult = await performWithRetries(
            loweredByTempra[identifier, default: []],
            attempts: attempts,
            operation: { await system.restorePriority($0) }
        )
        let unresolved = retryResult.unresolved
        if unresolved.isEmpty {
            priorityRestorationFailureDescriptions.removeValue(forKey: identifier)
        } else {
            priorityRestorationFailureDescriptions[identifier] =
                retryResult.failureDescription ?? "The process priority restore request failed."
        }
        if unresolved.isEmpty {
            loweredByTempra.removeValue(forKey: identifier)
            return workIsCurrent
        }
        loweredByTempra[identifier] = unresolved
        return false
    }

    private func performWithRetries(
        _ processes: Set<ProcessIdentity>,
        attempts: Int,
        operation: (Set<ProcessIdentity>) async -> ProcessOperationResult
    ) async -> ProcessRetryResult {
        var unresolved = processes
        var failureDescription: String?
        guard !unresolved.isEmpty else {
            return ProcessRetryResult(unresolved: [], failureDescription: nil)
        }

        for attempt in 0..<max(1, attempts) {
            guard workIsCurrent else { break }
            let result = await operation(unresolved)
            unresolved = result.failed
            if !unresolved.isEmpty, let detail = result.failureDescription {
                failureDescription = detail
            }
            guard workIsCurrent else { break }
            if unresolved.isEmpty { break }
            if attempt + 1 < attempts {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return ProcessRetryResult(
            unresolved: unresolved,
            failureDescription: failureDescription
        )
    }

    private func isFrontmost(_ app: ProcessControlTarget) async -> Bool {
        if let minimumRevision = foregroundActivationMinimumRevision[app.bundleIdentifier] {
            guard revision >= minimumRevision else { return true }
            foregroundActivationMinimumRevision.removeValue(forKey: app.bundleIdentifier)
        }
        if let protectionUntil = foregroundActivationProtectionUntil[app.bundleIdentifier] {
            if clock.now() < protectionUntil {
                return true
            }
            foregroundActivationProtectionUntil.removeValue(forKey: app.bundleIdentifier)
        }
        let now = clock.now()
        if app.isFrontmost {
            return true
        }
        if let lastFrontmostProbeAt {
            let elapsed = ProcessControlMath.timeInterval(
                lastFrontmostProbeAt.duration(to: now)
            )
            if elapsed >= 0, elapsed < frontmostProbeInterval {
                return cachedFrontmostIdentifier == app.bundleIdentifier
            }
        }
        let frontmostIdentifier = await frontmostProvider()
        cachedFrontmostIdentifier = frontmostIdentifier
        lastFrontmostProbeAt = clock.now()
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
            current: status,
            isCPULimitSessionActive: limitRuntimes[identifier]?.hasActivatedLimit == true
        ))
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
        return .normal
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

    private func scheduleNextTick(now: Date = Date()) {
        guard managementIsActive else { return }
        let audioClockNow = clock.now()
        var nextInterval: TimeInterval?
        func include(_ interval: TimeInterval) {
            let normalized = max(0.001, interval)
            nextInterval = min(nextInterval ?? normalized, normalized)
        }

        for (identifier, rule) in rules where rule.hasBehavior {
            guard let app = groups[identifier],
                  !app.isFrontmost,
                  !app.isProtectedByForegroundOverlay else {
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
            if rule.action != .none || rule.lowersCPUPriority {
                include(visibilityRecheckInterval)
            }
            if rule.action != .limit,
               (rule.action != .none || rule.lowersCPUPriority),
               app.windowVisibility.protectsFromDisruptiveManagement {
                continue
            }
            guard !(rule.onlyWhenHidden && !app.isHidden), rule.action != .none else {
                continue
            }
            let visibilityDelay = rule.action == .limit
                ? 0
                : app.windowVisibility.minimumDisruptiveDelay
            let ruleStart = backgroundStart.addingTimeInterval(max(
                rule.delaySeconds,
                visibilityDelay
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
        let wakeRegistration = ProcessControlWakeRegistration()
        tickTask = Task(priority: .high) { [weak self, clock] in
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    wakeRegistration.install(clock.scheduleWake(proposedDeadline) {
                        continuation.resume()
                    })
                }
            } onCancel: {
                wakeRegistration.cancel()
            }
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
              statuses[identifier]?.isActivelyLimitingCPU == true,
              let selection = limitSelections[identifier] else {
            return 0
        }
        let expectedControlledCPU = min(
            runtime.estimatedFullSpeedCPU,
            selection.controlledLimitPercent
        )
        return max(0, runtime.estimatedFullSpeedCPU - expectedControlledCPU)
    }

    private func snapshot() -> ProcessControlSnapshot {
        ProcessControlSnapshot(
            revision: revision,
            statuses: statuses,
            estimatedSavedCPUByIdentifier: Dictionary(uniqueKeysWithValues: groups.keys.map {
                ($0, estimatedSavedCPU(for: $0))
            }),
            activeCPULimitSessionIdentifiers: Set(limitRuntimes.compactMap { entry in
                entry.value.hasActivatedLimit ? entry.key : nil
            }),
            protectionReasonsByIdentifier: limitSelections.mapValues {
                $0.protectionReasons
            },
            scheduledTickInterval: scheduledTickInterval
        )
    }

}
