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

final class ProcessControlWakeRegistration: @unchecked Sendable {
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

    @TaskLocal private static var reconciliationContext: ProcessReconciliationContext?

    typealias LimitPhase = ProcessLimitSchedulerModel.Phase
    typealias LimitRuntime = ProcessLimitSchedulerModel.Runtime
    typealias LimitDeadline = ProcessLimitSchedulerModel.Deadline
    typealias LimitDeadlineQueue = ProcessLimitSchedulerModel.DeadlineQueue
    typealias LimitPulseArbiter = ProcessLimitSchedulerModel.PulseArbiter

    nonisolated private let serialExecutor = ProcessControlSerialExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        serialExecutor.asUnownedSerialExecutor()
    }

    private struct CriticalFileActivityCacheEntry: Sendable {
        let activity: ProcessCriticalFileActivity
        let expiresAt: ContinuousClock.Instant
    }

    struct AutomaticResumeChange: Sendable {
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

    let system: any ProcessSystemControlling
    let crashWatchdog: any ProcessCrashWatchdogControlling
    private let frontmostProvider: FrontmostProvider
    private let activateApplication: ApplicationAction
    private let hideApplication: ApplicationAction
    private let gracefulTerminateApplication: ApplicationAction
    private let relaunchApplication: AsyncApplicationAction
    private let controlInterval: TimeInterval
    private let minimumRunDuration: TimeInterval
    let clock: ProcessControlClock
    let signalTelemetry: ProcessControlSignalTelemetry
    private let failureRetryInterval: TimeInterval = 1
    private let criticalFileActivityProbeInterval: TimeInterval = 2
    private let networkSensitivityReleaseDelay: TimeInterval = 5
    private let frontmostProbeInterval: TimeInterval = 1
    private let userActivationProbeDuration: TimeInterval = 0.4
    private let foregroundActivationProtectionDuration: TimeInterval = 1
    private let audioProtectionReleaseDelay: TimeInterval = 15
    let restorationAttempts = 3
    private let visibilityRecheckInterval: TimeInterval = 1
    static let launchGracePeriod: TimeInterval = 60

    private var eventHandler: EventHandler?
    var groups: [String: ProcessControlTarget] = [:]
    var rules: [String: AppRule] = [:]
    private var backgroundSince: [String: Date] = [:]
    var stoppedByTempra: [String: Set<ProcessIdentity>] = [:]
    var loweredByTempra: [String: Set<ProcessIdentity>] = [:]
    var limitPulseLoweredProcesses: [String: Set<ProcessIdentity>] = [:]
    var limitPriorityProcesses: [String: Set<ProcessIdentity>] = [:]
    private var resumeRestorationFailureDescriptions: [String: String] = [:]
    private var priorityRestorationFailureDescriptions: [String: String] = [:]
    var limitRuntimes: [String: LimitRuntime] = [:]
    var limitSelections: [String: ProcessLimitSelection] = [:]
    private var pausedBaselineCPU: [String: Double] = [:]
    private var pauseActivationProbeUntil: [String: Date] = [:]
    var foregroundActivationProtectionUntil: [String: ContinuousClock.Instant] = [:]
    var foregroundActivationMinimumRevision: [String: UInt64] = [:]
    private var cachedFrontmostIdentifier: String?
    private var lastFrontmostProbeAt: ContinuousClock.Instant?
    private var networkSensitiveProcesses: [String: Set<ProcessIdentity>] = [:]
    private var networkSensitiveUntil: [String: [ProcessIdentity: ContinuousClock.Instant]] = [:]
    var downloadProtectedProcesses: [String: Set<ProcessIdentity>] = [:]
    private var criticalFileActivityCache: [ProcessIdentity: CriticalFileActivityCacheEntry] = [:]
    var automaticResumeIntervals: [ProcessIdentity: TimeInterval] = [:]
    private var automaticResumeStopOperations: [UUID: Set<ProcessIdentity>] = [:]
    private var crashWatchdogIsArmed = false
    private var signalStoppedAt: [ProcessIdentity: ContinuousClock.Instant] = [:]
    private var audioProtection = AudioProtectionTracker()
    private var hideRequested: Set<String> = []
    private var quitRequested: Set<String> = []
    private var statuses: [String: ManagementStatus] = [:]
    private var isEnabled = true
    private var isSystemTransitionSuspended = false
    var revision: UInt64 = 0
    private var stateID = UUID()
    private var isDrainingReconciliationQueue = false
    private var needsStateReconciliation = false
    private var needsCadenceTick = false
    var pendingLimitSchedulerGeneration: UInt64?
    private var reconciliationWaiters: [CheckedContinuation<Void, Never>] = []
    private var tickTask: Task<Void, Never>?
    var limitDeadlines = LimitDeadlineQueue()
    var limitPulseArbiter = LimitPulseArbiter()
    var limitSchedulerTask: Task<Void, Never>?
    var scheduledLimitDeadline: ContinuousClock.Instant?
    var limitSchedulerGeneration: UInt64 = 0
    private var scheduledTickInterval: TimeInterval?
    private var scheduledTickDeadline: ContinuousClock.Instant?
    private var isPauseWakeMonitoringEnabled = false

    var managementIsActive: Bool {
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

        groups = incomingGroups
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

    func requestLimitDeadlineProcessing(schedulerGeneration: UInt64) async {
        guard schedulerGeneration == limitSchedulerGeneration else { return }
        pendingLimitSchedulerGeneration = schedulerGeneration
        await drainReconciliationQueue()
    }

    var workIsCurrent: Bool {
        guard let context = Self.reconciliationContext else { return true }
        return context.stateID == stateID
    }
    private var currentReconciliationContext: ProcessReconciliationContext {
        Self.reconciliationContext
            ?? ProcessReconciliationContext(stateID: stateID, revision: revision)
    }

    private var eventRevision: UInt64 {
        Self.reconciliationContext?.revision ?? revision
    }

    func restore(bundleIdentifier: String) async -> ProcessControlSnapshot {
        let context = currentReconciliationContext
        return await Self.$reconciliationContext.withValue(context) {
            await restoreDirect(bundleIdentifier: bundleIdentifier)
        }
    }

    private func restoreDirect(
        bundleIdentifier: String
    ) async -> ProcessControlSnapshot {
        if await restore(identifier: bundleIdentifier, resetDelay: true, attempts: 3) {
            await setStatus(.normal, for: bundleIdentifier)
        } else {
            await markUnavailable(
                bundleIdentifier,
                detail: "Tempra could not restore every process."
            )
        }
        await updatePauseWakeMonitoring()
        guard workIsCurrent else { return snapshot() }
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
        let context = currentReconciliationContext
        return await Self.$reconciliationContext.withValue(context) {
            await applicationDidActivateDirect(bundleIdentifier: bundleIdentifier)
        }
    }

    private func applicationDidActivateDirect(
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
        guard workIsCurrent else { return snapshot() }
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
        guard workIsCurrent else { return snapshot() }

        if restored {
            await setStatus(.normal, for: bundleIdentifier)
        } else {
            await markUnavailable(
                bundleIdentifier,
                detail: "Tempra could not restore every process after the app became active."
            )
        }
        await updatePauseWakeMonitoring()
        guard workIsCurrent else { return snapshot() }
        scheduleLimitScheduler()
        scheduleNextTick()
        return snapshot()
    }

    func performApplicationCommand(
        _ command: ApplicationCommand,
        bundleIdentifier: String
    ) async -> ApplicationCommandOutcome {
        let context = currentReconciliationContext
        return await Self.$reconciliationContext.withValue(context) {
            await performApplicationCommandDirect(
                command,
                bundleIdentifier: bundleIdentifier
            )
        }
    }

    private func performApplicationCommandDirect(
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
            guard workIsCurrent else { return .failed(.restorationFailed) }
            await markUnavailable(
                bundleIdentifier,
                detail: "Tempra could not restore every process before the app command."
            )
            _ = await finishApplicationCommand()
            return .failed(.restorationFailed)
        }
        guard workIsCurrent else { return .failed(.restorationFailed) }

        await setStatus(.normal, for: bundleIdentifier)
        guard workIsCurrent else { return .failed(.requestRejected) }
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
        guard workIsCurrent else { return .failed(.requestRejected) }

        guard requestAccepted else {
            await emitActivity(
                bundleIdentifier,
                kind: .error,
                detail: "macOS did not accept the requested app command."
            )
            _ = await finishApplicationCommand()
            return .failed(.requestRejected)
        }

        switch command {
        case .bringToFront:
            break
        case .hide:
            guard workIsCurrent else { return .failed(.requestRejected) }
            hideRequested.insert(bundleIdentifier)
        case .quit, .quitGracefully:
            guard workIsCurrent else { return .failed(.requestRejected) }
            quitRequested.insert(bundleIdentifier)
            await setStatus(.waiting, for: bundleIdentifier)
            guard workIsCurrent else { return .failed(.requestRejected) }
            await emitActivity(
                bundleIdentifier,
                kind: command == .quit ? .quit : .gracefulQuit,
                detail: command == .quit
                    ? "Force quit from the process menu"
                    : "Quit request from the process menu"
            )
        case .relaunch:
            await setStatus(.normal, for: bundleIdentifier)
            guard workIsCurrent else { return .failed(.requestRejected) }
            await emitActivity(
                bundleIdentifier,
                kind: .relaunched,
                detail: "Relaunched from the process menu"
            )
        }

        guard await finishApplicationCommand() else {
            return .failed(.requestRejected)
        }
        return .succeeded
    }

    @discardableResult
    func restoreAll(attempts: Int = 3) async -> ProcessRestorationResult {
        let context = currentReconciliationContext
        return await Self.$reconciliationContext.withValue(context) {
            await restoreAllDirect(attempts: attempts)
        }
    }

    private func restoreAllDirect(attempts: Int) async -> ProcessRestorationResult {
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
        let context = currentReconciliationContext
        await Self.$reconciliationContext.withValue(context) {
            await wakePausedApplicationsForUserActivationDirect()
        }
    }

    private func wakePausedApplicationsForUserActivationDirect() async {
        guard managementIsActive else { return }
        let until = Date().addingTimeInterval(userActivationProbeDuration)
        for identifier in Array(stoppedByTempra.keys) where rules[identifier]?.action == .pause {
            let stopped = stoppedByTempra[identifier, default: []]
            let result = await resumeProcesses(
                stopped,
                identifier: identifier,
                reason: .userActivationProbe
            )
            guard workIsCurrent else { return }
            let synchronized = await setStoppedProcesses(result.failed, for: identifier)
            guard workIsCurrent else { return }
            if !synchronized {
                await markUnavailable(
                    identifier,
                    detail: "Tempra lost its process safety helper while resuming processes."
                )
                guard workIsCurrent else { return }
            }
            if !result.applied.isEmpty {
                pauseActivationProbeUntil[identifier] = until
            }
        }
        await updatePauseWakeMonitoring()
        guard workIsCurrent else { return }
        scheduleLimitScheduler()
        scheduleNextTick()
    }

    func currentSnapshot() -> ProcessControlSnapshot {
        snapshot()
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

    func latencySensitiveProcesses(
        for app: ProcessControlTarget
    ) -> Set<ProcessIdentity> {
        var processes = networkSensitiveProcesses[app.bundleIdentifier, default: []]
        processes.formUnion(app.processSamples.compactMap { sample in
            sample.networkActivity.isLatencySensitive ? sample.identity : nil
        })
        return processes.intersection(app.processIdentities)
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

    func criticalFileActivity(
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
                await deferForAudioProtection(rule: rule, app: app)
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

            if rule.action == .none,
               rule.lowersCPUPriority,
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

            let startDelay = rule.delaySeconds
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
            if await liveAudioBlocksAction(rule: rule, app: app) {
                guard workIsCurrent else { return }
                await deferForAudioProtection(rule: rule, app: app)
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

    /// Asks Core Audio whether the app is playing right before a disruptive
    /// action. The sample-driven listeners carry the steady state; this is the
    /// last check against a stale sample, so it never runs for an app whose
    /// processes Tempra has already stopped — they cannot start playing.
    private func liveAudioBlocksAction(
        rule: AppRule,
        app: ProcessControlTarget
    ) async -> Bool {
        guard rule.protectAudio,
              !app.processIdentities.isSubset(
                of: stoppedByTempra[app.bundleIdentifier, default: []]
              ) else {
            return false
        }
        let liveAudioActivity = await system.audioActivity(for: app.processIdentities)
        guard workIsCurrent else { return true }
        switch liveAudioActivity {
        case .active:
            return audioProtection.update(
                identifier: app.bundleIdentifier,
                isPlayingAudio: true,
                protectsAudio: true,
                now: clock.now(),
                releaseDelay: ProcessControlMath.duration(audioProtectionReleaseDelay)
            )
        case .unknown:
            return true
        case .inactive:
            return false
        }
    }

    private func deferForAudioProtection(
        rule: AppRule,
        app: ProcessControlTarget
    ) async {
        if await prepareForDeferredAction(
            rule: rule,
            app: app,
            appliesLowerPriority: false
        ) {
            guard workIsCurrent else { return }
            backgroundSince[app.bundleIdentifier] = Date()
            await setStatus(.audioProtected, for: app.bundleIdentifier)
        }
    }

    private func apply(
        rule: AppRule,
        to app: ProcessControlTarget,
        advancesLimitCycle: Bool
    ) async {
        guard workIsCurrent else { return }
        let identifier = app.bundleIdentifier
        if rule.action != .limit,
           let limitPriority = limitPriorityProcesses[identifier],
           !limitPriority.isEmpty {
            guard await restoreLimitPulsePriority(
                for: identifier,
                processes: limitPriority
            ) else {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore normal process priority before changing process control."
                )
                return
            }
            guard workIsCurrent else { return }
        }
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
        guard workIsCurrent else { return false }
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

    func stopProcesses(
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

    func resumeProcesses(
        _ processes: Set<ProcessIdentity>,
        identifier: String?,
        reason: ProcessControlSignalReason,
        retainingAutomaticResume retainedProcesses: Set<ProcessIdentity> = []
    ) async -> ProcessOperationResult {
        guard !processes.isEmpty else { return ProcessOperationResult() }
        let result = await system.resume(processes)
        guard workIsCurrent else { return result }
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

    func recordPreventedStop(
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

    func restore(
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

    func resumeStoppedProcesses(
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
        guard workIsCurrent else { return false }
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

    func trackStoppedProcessesFromStaleWork(
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

    func prepareWatchdogToStop(
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

    func armWatchdogAutomaticResume(
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

    func cancelWatchdogAutomaticResume(
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

    func setStoppedProcesses(
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
            guard workIsCurrent else { return false }
            let pending = allStoppedProcesses
            let emergencyResult = await resumeProcesses(
                pending,
                identifier: nil,
                reason: .emergencyRestoration
            )
            guard workIsCurrent else { return false }
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

    func restorationResult() -> ProcessRestorationResult {
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
        guard workIsCurrent else { return false }
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

    private func restoreLowerPriority(
        for identifier: String,
        attempts: Int
    ) async -> Bool {
        let retryResult = await performWithRetries(
            loweredByTempra[identifier, default: []],
            attempts: attempts,
            operation: { await system.restorePriority($0) }
        )
        guard workIsCurrent else { return false }
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

    func isFrontmost(_ app: ProcessControlTarget) async -> Bool {
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

    func readCPUTime(
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

    func setStatus(_ status: ManagementStatus, for identifier: String) async {
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

    func markUnavailable(_ identifier: String, detail: String) async {
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

    private func finishApplicationCommand() async -> Bool {
        await updatePauseWakeMonitoring()
        guard workIsCurrent else { return false }
        scheduleLimitScheduler()
        scheduleNextTick()
        return true
    }

    func updatePauseWakeMonitoring() async {
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

    func scheduleNextTick(now: Date = Date()) {
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
            if rule.action == .none,
               rule.lowersCPUPriority,
               app.windowVisibility.protectsFromDisruptiveManagement {
                continue
            }
            guard !(rule.onlyWhenHidden && !app.isHidden), rule.action != .none else {
                continue
            }
            let ruleStart = backgroundStart.addingTimeInterval(rule.delaySeconds)
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
