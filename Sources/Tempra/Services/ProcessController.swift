import AppKit
import Dispatch
import Foundation

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
    private let minimumLimitFrameDuration: TimeInterval = 0.1
    private let minimumLimitRestDuration: TimeInterval = 0.001
    private let networkMaximumLimitStopDuration: TimeInterval = 0.1
    private let offlineMaximumLimitStopDuration: TimeInterval = 0.5
    private let criticalFileActivityProbeInterval: TimeInterval = 2
    private let networkSensitivityReleaseDelay: TimeInterval = 5
    private let limitObservationInterval: TimeInterval = 1
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
    private var backgroundedByTempra: [String: Set<ProcessIdentity>] = [:]
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

        let changedRuleIdentifiers = Set(previousRules.keys).union(self.rules.keys).filter {
            previousRules[$0] != self.rules[$0]
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
            || backgroundedByTempra[bundleIdentifier]?.isEmpty == false
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
            await crashWatchdog.disarm()
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
            .union(backgroundedByTempra.keys)
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

    private func maximumLimitStopDuration(
        for identifier: String,
        processes: Set<ProcessIdentity>
    ) -> TimeInterval {
        guard let app = groups[identifier] else {
            return networkMaximumLimitStopDuration
        }
        let sensitiveProcesses = latencySensitiveProcesses(for: app).union(
            downloadProtectedProcesses[identifier, default: []]
        )
        return sensitiveProcesses.isDisjoint(with: processes)
            ? offlineMaximumLimitStopDuration
            : networkMaximumLimitStopDuration
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
            let priorityPrepared: Bool
            if rule.usesEfficiencyCoreScheduling {
                priorityPrepared = await applyBackgroundPriority(to: app)
            } else {
                priorityPrepared = await restoreBackgroundPriority(
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
                if rule.usesEfficiencyCoreScheduling { return }
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore normal process priority."
                )
                return
            }
            await setStatus(
                rule.usesEfficiencyCoreScheduling ? .energyEfficient : .normal,
                for: identifier
            )
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
            if rule.usesEfficiencyCoreScheduling {
                guard await applyBackgroundPriority(to: app) else { return }
            } else {
                guard await restoreBackgroundPriority(
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

    private func applyBackgroundPriority(to app: ProcessControlTarget) async -> Bool {
        guard workIsCurrent else { return false }
        let identifier = app.bundleIdentifier
        var existing = backgroundedByTempra[identifier, default: []]
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
                backgroundedByTempra[identifier] = existing
                return false
            }
            guard restoreResult.failed.isEmpty else {
                backgroundedByTempra[identifier] = existing.union(restoreResult.failed)
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore network or critical-activity processes to normal priority."
                )
                return false
            }
        }

        let result = await system.setBackgroundPriority(
            desired.subtracting(existing)
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

        let backgrounded = existing.union(result.applied).intersection(desired)
        if backgrounded.isEmpty {
            backgroundedByTempra.removeValue(forKey: identifier)
        } else {
            backgroundedByTempra[identifier] = backgrounded
        }
        return true
    }

    private func runLimitCycle(
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
        let maximumStopDuration = maximumLimitStopDuration(
            for: identifier,
            processes: controlledProcesses
        )
        let now = clock.now()
        guard let nowCPU = await readCPUTime(
            for: controlledProcesses,
            identifier: identifier
        ) else { return }
        let isStopped = !stoppedByTempra[identifier, default: []]
            .intersection(controlledProcesses).isEmpty
        let startsAboveLimit = selection.controlledCPUPercent
            > ProcessControlMath.activationThreshold(for: limitPercent)
        let initialEstimate = max(selection.controlledCPUPercent, limitPercent, 1)
        let initialCredit = initialLimitCredit(
            estimatedFullSpeedCPU: initialEstimate,
            limitPercent: limitPercent,
            maximumStopDuration: maximumStopDuration
        )
        var runtime = limitRuntimes[identifier] ?? LimitRuntime(
            lastCPUNanoseconds: nowCPU,
            lastAccountingAt: now,
            runStartedAt: isStopped ? nil : now,
            estimatedFullSpeedCPU: initialEstimate,
            cpuCreditNanoseconds: initialCredit,
            lastMeasuredCPUPercent: nil,
            demandProbeCPUNanoseconds: 0,
            demandProbeWallDuration: 0,
            hasActivatedLimit: isStopped || startsAboveLimit,
            stoppedAt: isStopped ? now : nil,
            generation: 0,
            phase: isStopped ? .stopped : (startsAboveLimit ? .running : .observing),
            processIdentities: controlledProcesses
        )
        var accountingElapsed = max(
            0,
            ProcessControlMath.timeInterval(runtime.lastAccountingAt.duration(to: now))
        )

        if runtime.processIdentities != controlledProcesses {
            runtime = LimitRuntime(
                lastCPUNanoseconds: nowCPU,
                lastAccountingAt: now,
                runStartedAt: isStopped ? nil : now,
                estimatedFullSpeedCPU: initialEstimate,
                cpuCreditNanoseconds: initialCredit,
                lastMeasuredCPUPercent: nil,
                demandProbeCPUNanoseconds: 0,
                demandProbeWallDuration: 0,
                hasActivatedLimit: runtime.hasActivatedLimit
                    || isStopped
                    || startsAboveLimit,
                stoppedAt: isStopped ? now : nil,
                generation: runtime.generation,
                phase: isStopped ? .stopped : (startsAboveLimit ? .running : .observing),
                processIdentities: controlledProcesses
            )
            accountingElapsed = 0
        } else if runtime.phase != .observing
                    || accountingElapsed >= limitObservationInterval {
            _ = updateLimitAccounting(
                runtime: &runtime,
                nowCPU: nowCPU,
                now: now,
                limitPercent: limitPercent,
                maximumStopDuration: maximumStopDuration
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
                await setStatus(.normal, for: identifier)
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
                await setStatus(.normal, for: identifier)
                return
            }

            runtime.hasActivatedLimit = true
            runtime.phase = .running
            runtime.runStartedAt = now
        }

        let wasStopped = runtime.phase == .stopped
        let estimatedCPUPerWallSecond = max(runtime.estimatedFullSpeedCPU / 100, 0.01)
        let affordableRunDuration = max(0, runtime.cpuCreditNanoseconds)
            / (estimatedCPUPerWallSecond * 1_000_000_000)
        let frameDuration = limitFrameDuration(
            estimatedFullSpeedCPU: runtime.estimatedFullSpeedCPU,
            limitPercent: limitPercent,
            maximumStopDuration: maximumStopDuration
        )
        let maximumPulseDuration = min(
            frameDuration,
            max(minimumRunDuration, controlInterval)
        )
        let runDuration = min(maximumPulseDuration, affordableRunDuration)
        runtime.lastCPUNanoseconds = nowCPU
        runtime.generation = ProcessControlMath.nextGeneration(after: runtime.generation)
        let generation = runtime.generation
        limitRuntimes[identifier] = runtime
        limitDeadlines.remove(identifier: identifier)

        if runDuration <= 0, !wasStopped {
            await finishLimitCycle(
                identifier: identifier,
                generation: generation,
                limitPercent: limitPercent,
                processIdentities: controlledProcesses
            )
            return
        }

        if wasStopped {
            guard await prepareLimitStop(
                controlledProcesses,
                identifier: identifier,
                generation: generation,
                requestedLimitPercent: requestedLimitPercent
            ) else {
                scheduleLimitScheduler()
                return
            }

            let arbitrationNow = clock.now()
            let expectedEnd = arbitrationNow.advanced(
                by: ProcessControlMath.duration(runDuration)
            )
            let stoppedAt = runtime.stoppedAt ?? now
            let latestStart = stoppedAt.advanced(
                by: ProcessControlMath.duration(maximumStopDuration)
            )
            let decision = limitPulseArbiter.decision(
                for: .init(
                    identifier: identifier,
                    generation: generation,
                    requestedAt: arbitrationNow,
                    latestStart: latestStart,
                    isLatencySensitive: maximumStopDuration
                        <= networkMaximumLimitStopDuration
                ),
                minimumGap: ProcessControlMath.duration(minimumLimitRestDuration)
            )
            if case .deferUntil(let deferredUntil) = decision {
                limitRuntimes[identifier] = runtime
                limitDeadlines.upsert(LimitDeadline(
                    identifier: identifier,
                    deadline: deferredUntil,
                    generation: generation,
                    limitPercent: limitPercent,
                    processIdentities: controlledProcesses,
                    kind: .evaluate
                ))
                scheduleLimitScheduler()
                await setStatus(
                    limitStatus(for: identifier, fallback: requestedLimitPercent),
                    for: identifier
                )
                return
            }
            limitPulseArbiter.acquire(
                identifier: identifier,
                generation: generation,
                expectedEnd: expectedEnd
            )
        }

        guard await resumeStoppedProcesses(for: identifier, attempts: restorationAttempts) else {
            limitPulseArbiter.release(identifier: identifier, generation: generation)
            await markUnavailable(identifier, detail: "Tempra could not resume every process.")
            return
        }

        guard let resumedCPUTime = await readCPUTime(
            for: controlledProcesses,
            identifier: identifier
        ) else {
            limitPulseArbiter.release(identifier: identifier, generation: generation)
            return
        }
        runtime.lastCPUNanoseconds = resumedCPUTime
        runtime.lastAccountingAt = clock.now()
        runtime.runStartedAt = runtime.lastAccountingAt
        runtime.stoppedAt = nil
        runtime.phase = .running
        runtime.processIdentities = controlledProcesses

        let stopDeadline = runtime.lastAccountingAt.advanced(
            by: ProcessControlMath.duration(runDuration)
        )
        limitPulseArbiter.acquire(
            identifier: identifier,
            generation: generation,
            expectedEnd: stopDeadline
        )
        limitRuntimes[identifier] = runtime
        if runDuration <= 0 {
            await finishLimitCycle(
                identifier: identifier,
                generation: generation,
                limitPercent: limitPercent,
                processIdentities: controlledProcesses
            )
            return
        }
        limitDeadlines.upsert(LimitDeadline(
            identifier: identifier,
            deadline: stopDeadline,
            generation: generation,
            limitPercent: limitPercent,
            processIdentities: controlledProcesses,
            kind: .stop
        ))
        await setStatus(limitStatus(for: identifier, fallback: requestedLimitPercent), for: identifier)
    }

    @discardableResult
    private func updateLimitAccounting(
        runtime: inout LimitRuntime,
        nowCPU: UInt64,
        now: ContinuousClock.Instant,
        limitPercent: Double,
        maximumStopDuration: TimeInterval
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
            if runDuration > 0 {
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
        let allowedFrameCredit = limitFrameDuration(
            estimatedFullSpeedCPU: runtime.estimatedFullSpeedCPU,
            limitPercent: limitPercent,
            maximumStopDuration: maximumStopDuration
        ) * allowedCPUPerSecond
        let maximumCredit = allowedFrameCredit
        let maximumDebt = max(allowedFrameCredit, minimumSliceCost)
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
        let maximumStopDuration = maximumLimitStopDuration(
            for: identifier,
            processes: runtime.processIdentities
        )
        let allowedCPUPerSecond = max(0, limitPercent) / 100 * 1_000_000_000
        let frameDuration = limitFrameDuration(
            estimatedFullSpeedCPU: runtime.estimatedFullSpeedCPU,
            limitPercent: limitPercent,
            maximumStopDuration: maximumStopDuration
        )
        let frameCredit = frameDuration * allowedCPUPerSecond
        let creditNeeded = max(0, frameCredit - runtime.cpuCreditNanoseconds)
        let creditWait = allowedCPUPerSecond > 0
            ? creditNeeded / allowedCPUPerSecond
            : maximumStopDuration
        let estimatedDemand = max(runtime.estimatedFullSpeedCPU, 0.01)
        let targetDutyCycle = min(1, max(0, limitPercent) / estimatedDemand)
        let targetRunDuration = frameDuration * targetDutyCycle
        let targetRestDuration = max(
            minimumLimitRestDuration,
            frameDuration - targetRunDuration
        )
        let stopDuration = min(
            maximumStopDuration,
            max(targetRestDuration, creditWait)
        )
        limitDeadlines.upsert(LimitDeadline(
            identifier: identifier,
            deadline: now.advanced(by: ProcessControlMath.duration(stopDuration)),
            generation: runtime.generation,
            limitPercent: limitPercent,
            processIdentities: runtime.processIdentities,
            kind: .evaluate
        ))
    }

    private func limitFrameDuration(
        estimatedFullSpeedCPU: Double,
        limitPercent: Double,
        maximumStopDuration: TimeInterval
    ) -> TimeInterval {
        let normalizedLimit = max(limitPercent, CPULimitRange.minimumPercent)
        let demandRatio = max(estimatedFullSpeedCPU, normalizedLimit) / normalizedLimit
        return min(
            maximumStopDuration,
            max(minimumLimitFrameDuration, minimumRunDuration * demandRatio)
        )
    }

    private func initialLimitCredit(
        estimatedFullSpeedCPU: Double,
        limitPercent: Double,
        maximumStopDuration: TimeInterval
    ) -> Double {
        let allowedCPUPerSecond = max(0, limitPercent) / 100 * 1_000_000_000
        let frameCredit = limitFrameDuration(
            estimatedFullSpeedCPU: estimatedFullSpeedCPU,
            limitPercent: limitPercent,
            maximumStopDuration: maximumStopDuration
        ) * allowedCPUPerSecond
        return frameCredit
    }

    private func updateDemandProbe(
        runtime: inout LimitRuntime,
        cpuDeltaNanoseconds: UInt64?,
        wallDuration: TimeInterval?
    ) -> Double? {
        guard let cpuDeltaNanoseconds,
              let wallDuration,
              wallDuration.isFinite,
              wallDuration > 0 else {
            return nil
        }
        runtime.demandProbeCPUNanoseconds = min(
            Double.greatestFiniteMagnitude,
            runtime.demandProbeCPUNanoseconds + Double(cpuDeltaNanoseconds)
        )
        runtime.demandProbeWallDuration = min(
            Double.greatestFiniteMagnitude,
            runtime.demandProbeWallDuration + wallDuration
        )
        guard runtime.demandProbeWallDuration >= minimumRunDuration else {
            return nil
        }
        let measuredCPU = runtime.demandProbeCPUNanoseconds
            / (runtime.demandProbeWallDuration * 1_000_000_000)
            * 100
        runtime.demandProbeCPUNanoseconds = 0
        runtime.demandProbeWallDuration = 0
        return measuredCPU
    }

    private func prepareLimitStop(
        _ processes: Set<ProcessIdentity>,
        identifier: String,
        generation: UInt64,
        requestedLimitPercent: Double
    ) async -> Bool {
        var activeProcesses: Set<ProcessIdentity> = []
        var unavailableProcesses: Set<ProcessIdentity> = []
        var activeDownloadProcesses: Set<ProcessIdentity> = []
        var inactiveDownloadProcesses: Set<ProcessIdentity> = []

        for process in processes.sorted(by: { $0.pid < $1.pid }) {
            let activity = await system.networkActivity(for: process)
            guard workIsCurrent,
                  limitControlIsCurrent(
                    identifier: identifier,
                    generation: generation,
                    processIdentities: processes
                  ) else {
                return false
            }
            switch activity {
            case .active:
                activeProcesses.insert(process)
            case .unknown:
                unavailableProcesses.insert(process)
            case .inactive:
                break
            }

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

        guard !activeProcesses.isEmpty
                || !unavailableProcesses.isEmpty
                || !activeDownloadProcesses.isEmpty else {
            return true
        }

        let sensitiveProcesses = activeProcesses.union(unavailableProcesses)
        markNetworkSensitive(sensitiveProcesses, for: identifier)
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
            if !activeProcesses.isEmpty {
                await recordPreventedStop(
                    activeProcesses,
                    identifier: identifier,
                    reason: .networkActive
                )
            }
            if !unavailableProcesses.isEmpty {
                await recordPreventedStop(
                    unavailableProcesses,
                    identifier: identifier,
                    reason: .networkProbeUnavailable
                )
            }
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
            ? maximumLimitStopDuration(for: identifier, processes: processes)
            : nil
        let result = await system.stop(
            processes,
            automaticResumeAfter: automaticResumeAfter
        )
        if reason == .cpuLimitPulse {
            if let automaticResumeOperationID {
                automaticResumeStopOperations.removeValue(forKey: automaticResumeOperationID)
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
        reason: ProcessControlSignalReason
    ) async -> ProcessOperationResult {
        guard !processes.isEmpty else { return ProcessOperationResult() }
        let result = await system.resume(processes)
        let stillPending = automaticResumeStopOperations.values.reduce(
            into: Set<ProcessIdentity>()
        ) { pending, operationProcesses in
            pending.formUnion(operationProcesses)
        }
        for process in result.applied.union(result.stale).subtracting(stillPending) {
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
        guard let runtime = limitRuntimes[identifier] else { return }
        let generation = runtime.generation

        if runtime.processIdentities != selection.controlledProcesses {
            limitPulseArbiter.release(identifier: identifier)
            limitDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            await runLimitCycle(for: app, limitPercent: requestedLimitPercent)
            return
        }

        guard runtime.phase == .stopped else {
            await setStatus(
                runtime.phase == .observing
                    ? .normal
                    : limitStatus(for: identifier, fallback: requestedLimitPercent),
                for: identifier
            )
            return
        }

        guard await prepareWatchdogToStop(runtime.processIdentities, for: identifier) else {
            limitRuntimes.removeValue(forKey: identifier)
            return
        }
        guard await prepareLimitStop(
            runtime.processIdentities,
            identifier: identifier,
            generation: generation,
            requestedLimitPercent: requestedLimitPercent
        ) else {
            return
        }
        guard let newlyArmedProcesses = await armWatchdogAutomaticResume(
            runtime.processIdentities,
            for: identifier
        ) else {
            return
        }
        guard limitControlIsCurrent(
            identifier: identifier,
            generation: generation,
            processIdentities: runtime.processIdentities
        ) else {
            await cancelWatchdogAutomaticResume(
                newlyArmedProcesses,
                for: identifier
            )
            return
        }
        let result = await stopProcesses(
            runtime.processIdentities,
            identifier: identifier,
            reason: .cpuLimitPulse
        )
        guard workIsCurrent else {
            await trackStoppedProcessesFromStaleWork(result.applied, for: identifier)
            return
        }
        guard limitControlIsCurrent(
            identifier: identifier,
            generation: generation,
            processIdentities: runtime.processIdentities
        ) else {
            await resumeProcessesStoppedByObsoleteLimit(result.applied, for: identifier)
            return
        }
        guard result.failed.isEmpty else {
            let rollback = await resumeProcesses(
                result.applied,
                identifier: identifier,
                reason: .stopRollback
            )
            limitRuntimes.removeValue(forKey: identifier)
            _ = await setStoppedProcesses(rollback.failed, for: identifier)
            let priorityRollback = await system.restorePriority(
                backgroundedByTempra[identifier, default: []]
            )
            if priorityRollback.failed.isEmpty {
                backgroundedByTempra.removeValue(forKey: identifier)
            } else {
                backgroundedByTempra[identifier] = priorityRollback.failed
            }
            await markUnavailable(identifier, detail: "Tempra could not limit every process.")
            return
        }
        guard !result.applied.isEmpty else {
            limitRuntimes.removeValue(forKey: identifier)
            _ = await setStoppedProcesses([], for: identifier)
            await setStatus(.normal, for: identifier)
            return
        }
        guard await setStoppedProcesses(result.applied, for: identifier) else {
            limitRuntimes.removeValue(forKey: identifier)
            return
        }
        guard workIsCurrent else { return }
        await setStatus(
            limitStatus(for: identifier, fallback: requestedLimitPercent),
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
        defer {
            limitPulseArbiter.release(identifier: identifier, generation: generation)
        }
        guard managementIsActive,
              let app = groups[identifier],
              processIdentities.isSubset(of: app.processIdentities),
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
        guard managementIsActive,
              let currentApp = groups[identifier],
              processIdentities.isSubset(of: currentApp.processIdentities),
              limitRuntimes[identifier]?.generation == generation,
              rules[identifier]?.action == .limit else {
            return
        }

        guard await prepareWatchdogToStop(processIdentities, for: identifier) else {
            limitRuntimes.removeValue(forKey: identifier)
            scheduleNextTick()
            return
        }
        guard await prepareLimitStop(
            processIdentities,
            identifier: identifier,
            generation: generation,
            requestedLimitPercent: rules[identifier]?.limitPercent ?? limitPercent
        ) else {
            scheduleNextTick()
            return
        }
        guard let newlyArmedProcesses = await armWatchdogAutomaticResume(
            processIdentities,
            for: identifier
        ) else {
            scheduleNextTick()
            return
        }
        guard limitControlIsCurrent(
            identifier: identifier,
            generation: generation,
            processIdentities: processIdentities
        ) else {
            await cancelWatchdogAutomaticResume(
                newlyArmedProcesses,
                for: identifier
            )
            scheduleNextTick()
            return
        }
        let result = await stopProcesses(
            processIdentities,
            identifier: identifier,
            reason: .cpuLimitPulse
        )
        guard workIsCurrent else {
            await trackStoppedProcessesFromStaleWork(result.applied, for: identifier)
            return
        }
        guard limitControlIsCurrent(
            identifier: identifier,
            generation: generation,
            processIdentities: processIdentities
        ) else {
            await resumeProcessesStoppedByObsoleteLimit(result.applied, for: identifier)
            scheduleNextTick()
            return
        }
        guard result.failed.isEmpty else {
            let rollback = await resumeProcesses(
                result.applied,
                identifier: identifier,
                reason: .stopRollback
            )
            limitRuntimes.removeValue(forKey: identifier)
            _ = await setStoppedProcesses(rollback.failed, for: identifier)
            let priorityRollback = await system.restorePriority(
                backgroundedByTempra[identifier, default: []]
            )
            if priorityRollback.failed.isEmpty {
                backgroundedByTempra.removeValue(forKey: identifier)
            } else {
                backgroundedByTempra[identifier] = priorityRollback.failed
            }
            await markUnavailable(identifier, detail: "Tempra could not limit every process.")
            scheduleNextTick()
            return
        }
        guard !result.applied.isEmpty else {
            limitRuntimes.removeValue(forKey: identifier)
            _ = await setStoppedProcesses([], for: identifier)
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
            let pulseStartedAt = runtime.runStartedAt
            let pulseStartingCPUTime = runtime.lastCPUNanoseconds
            guard let stoppedCPUTime = await readCPUTime(
                for: processIdentities,
                identifier: identifier
            ) else {
                guard workIsCurrent else { return }
                limitRuntimes.removeValue(forKey: identifier)
                scheduleNextTick()
                return
            }
            let pulseWallDuration = pulseStartedAt.map {
                max(0, ProcessControlMath.timeInterval($0.duration(to: stoppedAt)))
            }
            let pulseCPUDelta = stoppedCPUTime >= pulseStartingCPUTime
                ? stoppedCPUTime - pulseStartingCPUTime
                : nil
            let measuredCPU = updateLimitAccounting(
                runtime: &runtime,
                nowCPU: stoppedCPUTime,
                now: stoppedAt,
                limitPercent: limitPercent,
                maximumStopDuration: maximumLimitStopDuration(
                    for: identifier,
                    processes: processIdentities
                )
            )
            let demandProbeCPU = updateDemandProbe(
                runtime: &runtime,
                cpuDeltaNanoseconds: pulseCPUDelta,
                wallDuration: pulseWallDuration
            )
            await signalTelemetry.recordMeasurement(ProcessLimitMeasurement(
                date: Date(),
                bundleIdentifier: identifier,
                kind: .pulse,
                requestedLimitPercent: limitPercent,
                measuredCPUPercent: measuredCPU,
                cpuDeltaNanoseconds: pulseCPUDelta,
                wallDuration: pulseWallDuration,
                deadlineLateness: nil,
                activePulseCount: limitPulseArbiter.activeCount,
                serviceGap: nil
            ))
            if let demandProbeCPU,
               demandProbeCPU <= ProcessControlMath.releaseThreshold(for: limitPercent) {
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
                    for: processIdentities,
                    identifier: identifier
                ) else {
                    guard workIsCurrent else { return }
                    limitRuntimes.removeValue(forKey: identifier)
                    _ = await setStoppedProcesses(
                        stoppedByTempra[identifier, default: []],
                        for: identifier
                    )
                    scheduleNextTick()
                    return
                }
                runtime.lastCPUNanoseconds = observationCPUTime
                runtime.lastAccountingAt = observationStartedAt
                runtime.runStartedAt = observationStartedAt
                runtime.cpuCreditNanoseconds = initialLimitCredit(
                    estimatedFullSpeedCPU: runtime.estimatedFullSpeedCPU,
                    limitPercent: limitPercent,
                    maximumStopDuration: maximumLimitStopDuration(
                        for: identifier,
                        processes: processIdentities
                    )
                )
                runtime.stoppedAt = nil
                runtime.phase = .observing
                runtime.generation = ProcessControlMath.nextGeneration(
                    after: runtime.generation
                )
                runtime.processIdentities = processIdentities
                limitRuntimes[identifier] = runtime
                guard await setStoppedProcesses(
                    stoppedByTempra[identifier, default: []],
                    for: identifier
                ) else {
                    limitRuntimes.removeValue(forKey: identifier)
                    scheduleNextTick()
                    return
                }
                scheduleLimitObservation(
                    for: identifier,
                    runtime: runtime,
                    limitPercent: limitPercent,
                    now: observationStartedAt,
                    after: limitObservationInterval
                )
                await setStatus(.normal, for: identifier)
                await updatePauseWakeMonitoring()
                return
            }
            runtime.phase = .stopped
            runtime.runStartedAt = nil
            runtime.stoppedAt = stoppedAt
            runtime.generation = ProcessControlMath.nextGeneration(after: runtime.generation)
            runtime.processIdentities = processIdentities
            limitRuntimes[identifier] = runtime
            scheduleLimitEvaluation(
                for: identifier,
                runtime: runtime,
                limitPercent: limitPercent,
                now: stoppedAt
            )
        }
        await setStatus(limitStatus(for: identifier, fallback: limitPercent), for: identifier)
        await updatePauseWakeMonitoring()
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
        for identifier in Set(stoppedByTempra.keys).union(backgroundedByTempra.keys) {
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
        attempts: Int,
        resumeReason: ProcessControlSignalReason = .restoration
    ) async -> Bool {
        let priorityRestored = await restoreBackgroundPriority(
            for: identifier,
            attempts: attempts
        )
        guard workIsCurrent else { return false }
        let resumed = await restoreDisruptiveControl(
            identifier: identifier,
            attempts: attempts,
            resumeReason: resumeReason
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
        let priorityRestored = await restoreBackgroundPriority(
            for: identifier,
            attempts: attempts
        )
        guard workIsCurrent else { return false }
        let resumed = await restoreDisruptiveControl(identifier: identifier, attempts: attempts)
        return resumed && priorityRestored && workIsCurrent
    }

    private func restoreDisruptiveControl(
        identifier: String,
        attempts: Int,
        resumeReason: ProcessControlSignalReason = .restoration
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
            reason: resumeReason
        )
    }

    private func prepareForDeferredAction(
        rule: AppRule,
        app: ProcessControlTarget,
        appliesEfficiencyCores: Bool
    ) async -> Bool {
        guard workIsCurrent else { return false }
        let identifier = app.bundleIdentifier
        let priorityPrepared: Bool
        if appliesEfficiencyCores, rule.usesEfficiencyCoreScheduling {
            priorityPrepared = await applyBackgroundPriority(to: app)
        } else {
            priorityPrepared = await restoreBackgroundPriority(
                for: identifier,
                attempts: restorationAttempts
            )
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
            attempts: restorationAttempts
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
        reason: ProcessControlSignalReason = .restoration
    ) async -> Bool {
        let unresolved = await performWithRetries(
            stoppedByTempra[identifier, default: []],
            attempts: attempts,
            operation: {
                await resumeProcesses($0, identifier: identifier, reason: reason)
            }
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
        for identifier: String
    ) async -> AutomaticResumeChange? {
        guard workIsCurrent, !processes.isEmpty else { return nil }
        let userOwnedProcesses = Set(processes.lazy.filter {
            !$0.requiresPrivilegedControl
        })
        guard !userOwnedProcesses.isEmpty else { return .empty }
        let interval = maximumLimitStopDuration(
            for: identifier,
            processes: processes
        )
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

        do {
            try await crashWatchdog.synchronize(allWatchdogProtectedProcesses)
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
