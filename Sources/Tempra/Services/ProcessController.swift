import AppKit
import Foundation

struct ProcessControlClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleepUntil: @Sendable (ContinuousClock.Instant) async -> Void

    static let continuous: ProcessControlClock = {
        let clock = ContinuousClock()
        return ProcessControlClock(
            now: { clock.now },
            sleepUntil: { deadline in
                try? await clock.sleep(until: deadline)
            }
        )
    }()
}

actor ProcessController {
    typealias EventHandler = @MainActor @Sendable (ProcessControllerEvent) -> Void
    typealias FrontmostProvider = @MainActor @Sendable () -> String?
    typealias ApplicationAction = @MainActor @Sendable (String) -> Bool
    typealias WindowSnapshotProvider = @Sendable () -> WindowVisibilitySnapshot?

    private enum LimitPhase: Sendable {
        case running
        case stopped
    }

    private enum TickTrigger {
        case stateUpdate
        case cadence
    }

    private struct LimitRuntime: Sendable {
        var lastCPUNanoseconds: UInt64
        var lastRunDuration: TimeInterval
        var estimatedFullSpeedCPU: Double
        var cpuCreditNanoseconds: Double
        var generation: Int
        var phase: LimitPhase
        var processIdentities: Set<ProcessIdentity>
    }

    private struct LimitStopDeadline: Sendable {
        let identifier: String
        let deadline: ContinuousClock.Instant
        let generation: Int
        let limitPercent: Double
        let processIdentities: Set<ProcessIdentity>
    }

    private struct LimitStopDeadlineQueue: Sendable {
        private var heap: [LimitStopDeadline] = []
        private var indicesByIdentifier: [String: Int] = [:]

        var first: LimitStopDeadline? {
            heap.first
        }

        mutating func upsert(_ entry: LimitStopDeadline) {
            if let index = indicesByIdentifier[entry.identifier] {
                heap[index] = entry
                if !siftUp(from: index) {
                    siftDown(from: index)
                }
                return
            }

            let index = heap.endIndex
            heap.append(entry)
            indicesByIdentifier[entry.identifier] = index
            _ = siftUp(from: index)
        }

        @discardableResult
        mutating func remove(identifier: String) -> LimitStopDeadline? {
            guard let index = indicesByIdentifier[identifier] else { return nil }
            return remove(at: index)
        }

        mutating func popFirst() -> LimitStopDeadline? {
            guard !heap.isEmpty else { return nil }
            return remove(at: heap.startIndex)
        }

        mutating func removeAll() {
            heap.removeAll(keepingCapacity: true)
            indicesByIdentifier.removeAll(keepingCapacity: true)
        }

        private mutating func remove(at index: Int) -> LimitStopDeadline {
            let lastIndex = heap.index(before: heap.endIndex)
            if index != lastIndex {
                swapEntries(at: index, and: lastIndex)
            }
            let removed = heap.removeLast()
            indicesByIdentifier.removeValue(forKey: removed.identifier)
            if index < heap.endIndex, !siftUp(from: index) {
                siftDown(from: index)
            }
            return removed
        }

        @discardableResult
        private mutating func siftUp(from initialIndex: Int) -> Bool {
            var index = initialIndex
            var moved = false
            while index > heap.startIndex {
                let parent = (index - 1) / 2
                guard isOrderedBefore(heap[index], heap[parent]) else { break }
                swapEntries(at: index, and: parent)
                index = parent
                moved = true
            }
            return moved
        }

        private mutating func siftDown(from initialIndex: Int) {
            var index = initialIndex
            while true {
                let left = index * 2 + 1
                guard left < heap.endIndex else { return }
                let right = left + 1
                let candidate: Int
                if right < heap.endIndex, isOrderedBefore(heap[right], heap[left]) {
                    candidate = right
                } else {
                    candidate = left
                }
                guard isOrderedBefore(heap[candidate], heap[index]) else { return }
                swapEntries(at: index, and: candidate)
                index = candidate
            }
        }

        private mutating func swapEntries(at firstIndex: Int, and secondIndex: Int) {
            heap.swapAt(firstIndex, secondIndex)
            indicesByIdentifier[heap[firstIndex].identifier] = firstIndex
            indicesByIdentifier[heap[secondIndex].identifier] = secondIndex
        }

        private func isOrderedBefore(
            _ first: LimitStopDeadline,
            _ second: LimitStopDeadline
        ) -> Bool {
            if first.deadline != second.deadline {
                return first.deadline < second.deadline
            }
            return first.identifier < second.identifier
        }
    }

    private let system: any ProcessSystemControlling
    private let crashWatchdog: any ProcessCrashWatchdogControlling
    private let frontmostProvider: FrontmostProvider
    private let hideApplication: ApplicationAction
    private let terminateApplication: ApplicationAction
    private let windowSnapshotProvider: WindowSnapshotProvider
    private let controlInterval: TimeInterval
    private let minimumRunDuration: TimeInterval
    private let clock: ProcessControlClock
    private let failureRetryInterval: TimeInterval = 1
    private let userActivationProbeDuration: TimeInterval = 0.4
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
    private var hideRequested: Set<String> = []
    private var quitRequested: Set<String> = []
    private var statuses: [String: ManagementStatus] = [:]
    private var isEnabled = true
    private var revision: UInt64 = 0
    private var tickTask: Task<Void, Never>?
    private var limitStopDeadlines = LimitStopDeadlineQueue()
    private var limitStopSchedulerTask: Task<Void, Never>?
    private var scheduledLimitStopDeadline: ContinuousClock.Instant?
    private var limitStopSchedulerGeneration: UInt64 = 0
    private var scheduledTickInterval: TimeInterval?
    private var scheduledTickDeadline: ContinuousClock.Instant?
    private var isPauseWakeMonitoringEnabled = false

    init(
        system: any ProcessSystemControlling = LiveProcessSystemController(),
        crashWatchdog: any ProcessCrashWatchdogControlling = ProcessCrashWatchdog(),
        frontmostProvider: @escaping FrontmostProvider = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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
                .map { $0.terminate() }
                .contains(true)
        },
        windowSnapshotProvider: @escaping WindowSnapshotProvider = {
            WindowVisibilitySnapshot.capture()
        },
        controlInterval: TimeInterval = 0.5,
        minimumRunDuration: TimeInterval = 0.005,
        clock: ProcessControlClock = .continuous
    ) {
        self.system = system
        self.crashWatchdog = crashWatchdog
        self.frontmostProvider = frontmostProvider
        self.hideApplication = hideApplication
        self.terminateApplication = terminateApplication
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
        groups = Dictionary(uniqueKeysWithValues: targets.map { ($0.bundleIdentifier, $0) })
        self.rules = rules
        self.isEnabled = isEnabled

        let changedRuleIdentifiers = Set(previousRules.keys).union(rules.keys).filter {
            previousRules[$0] != rules[$0]
        }
        for identifier in changedRuleIdentifiers {
            limitStopDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
        }

        await reconcileControlledProcesses()

        let activeIdentifiers = Set(groups.keys)
        let inactiveIdentifiers = trackedIdentifiers.subtracting(activeIdentifiers)
        for identifier in inactiveIdentifiers {
            if await restore(identifier: identifier, resetDelay: true, attempts: restorationAttempts) {
                await setStatus(.normal, for: identifier)
                statuses.removeValue(forKey: identifier)
            } else {
                await markUnavailable(identifier, detail: "Tempra could not restore every process.")
            }
        }

        for identifier in Array(statuses.keys) where rules[identifier] == nil {
            if await restore(identifier: identifier, resetDelay: true, attempts: restorationAttempts) {
                await setStatus(.normal, for: identifier)
                statuses.removeValue(forKey: identifier)
            } else {
                await markUnavailable(identifier, detail: "Tempra could not restore every process.")
            }
        }

        if isEnabled {
            await tick(trigger: .stateUpdate)
        } else {
            _ = await restoreAll(attempts: 3)
        }
        return snapshot()
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
        scheduleLimitStopScheduler()
        scheduleNextTick()
        return snapshot()
    }

    @discardableResult
    func restoreAll(attempts: Int = 3) async -> ProcessRestorationResult {
        tickTask?.cancel()
        tickTask = nil
        scheduledTickInterval = nil
        scheduledTickDeadline = nil
        resetLimitStopScheduler()

        for identifier in trackedIdentifiers {
            if await restore(identifier: identifier, resetDelay: true, attempts: attempts) {
                await setStatus(.normal, for: identifier)
            } else {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore every process."
                )
            }
        }
        statuses = statuses.filter { $0.value == .unavailable }
        await updatePauseWakeMonitoring()
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
            let result = system.resume(stopped)
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
        scheduleLimitStopScheduler()
        scheduleNextTick()
    }

    func currentSnapshot() -> ProcessControlSnapshot {
        snapshot()
    }

    @discardableResult
    func shutdown() async -> ProcessRestorationResult {
        isEnabled = false
        let result = await restoreAll(attempts: 3)
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

    private func tick(trigger: TickTrigger) async {
        if trigger == .cadence {
            tickTask = nil
            scheduledTickInterval = nil
            scheduledTickDeadline = nil
        }
        guard isEnabled else {
            await updatePauseWakeMonitoring()
            return
        }
        let now = Date()
        if trigger == .cadence {
            refreshWindowVisibility()
        }

        for app in groups.values {
            let identifier = app.bundleIdentifier
            guard let rule = rules[identifier], rule.hasBehavior else {
                if await restore(identifier: identifier, resetDelay: true, attempts: restorationAttempts) {
                    await setStatus(.normal, for: identifier)
                } else {
                    await markUnavailable(
                        identifier,
                        detail: "Tempra could not restore every process."
                    )
                }
                continue
            }

            if await isFrontmost(app) {
                if await restore(identifier: identifier, resetDelay: true, attempts: restorationAttempts) {
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
                    await setStatus(
                        isWithinLaunchGrace
                            ? .waiting
                            : (rule.runOnEfficiencyCores ? .energyEfficient : .normal),
                        for: identifier
                    )
                }
                continue
            }

            if rule.protectAudio && app.isPlayingAudio {
                if await prepareForDeferredAction(
                    rule: rule,
                    app: app,
                    appliesEfficiencyCores: false
                ) {
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
                    backgroundSince[identifier] = backgroundStart
                    await setStatus(.waiting, for: identifier)
                }
                continue
            }

            if await applyIdleActions(
                for: app,
                rule: rule,
                backgroundDuration: backgroundDuration
            ) {
                if await restoreProcessControl(identifier: identifier, attempts: restorationAttempts) {
                    await setStatus(.waiting, for: identifier)
                } else {
                    await markUnavailable(
                        identifier,
                        detail: "Tempra could not restore every process after requesting quit."
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
                    backgroundSince[identifier] = backgroundStart
                    await setStatus(
                        rule.runOnEfficiencyCores ? .energyEfficient : .waiting,
                        for: identifier
                    )
                }
                continue
            }

            await apply(
                rule: rule,
                to: app,
                advancesLimitCycle: trigger == .cadence
            )
        }
        await updatePauseWakeMonitoring()
        scheduleLimitStopScheduler()
        scheduleNextTick()
    }

    private func apply(
        rule: AppRule,
        to app: ProcessControlTarget,
        advancesLimitCycle: Bool
    ) async {
        let identifier = app.bundleIdentifier
        switch rule.action {
        case .none:
            limitStopDeadlines.remove(identifier: identifier)
            limitRuntimes.removeValue(forKey: identifier)
            pausedBaselineCPU.removeValue(forKey: identifier)
            guard await resumeStoppedProcesses(for: identifier, attempts: restorationAttempts) else {
                await markUnavailable(identifier, detail: "Tempra could not resume every process.")
                return
            }
            if rule.runOnEfficiencyCores {
                if await applyBackgroundPriority(to: app) {
                    await setStatus(.energyEfficient, for: identifier)
                }
            } else if await restoreBackgroundPriority(
                for: identifier,
                attempts: restorationAttempts
            ) {
                await setStatus(.normal, for: identifier)
            } else {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore normal process priority."
                )
            }
        case .pause:
            limitStopDeadlines.remove(identifier: identifier)
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
            pausedBaselineCPU[identifier] = pausedBaselineCPU[identifier]
                ?? max(0, app.cpuPercent)
            if await maintainPause(for: app) {
                await setStatus(.paused, for: identifier)
            }
        case .limit:
            pausedBaselineCPU.removeValue(forKey: identifier)
            if rule.runOnEfficiencyCores {
                guard await applyBackgroundPriority(to: app) else { return }
            } else if !(await restoreBackgroundPriority(
                for: identifier,
                attempts: restorationAttempts
            )) {
                await markUnavailable(
                    identifier,
                    detail: "Tempra could not restore normal process priority."
                )
                return
            }
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
        let identifier = app.bundleIdentifier

        if let hideAfterMinutes = rule.hideAfterMinutes,
           backgroundDuration >= hideAfterMinutes * 60,
           !app.isHidden,
           !hideRequested.contains(identifier),
           await hideApplication(identifier) {
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
           await terminateApplication(identifier) {
            quitRequested.insert(identifier)
            await emitActivity(
                identifier,
                kind: .quit,
                detail: "Quit after \(Int(quitAfterMinutes)) minutes"
            )
            return true
        }
        return false
    }

    private func maintainPause(for app: ProcessControlTarget) async -> Bool {
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
        let result = system.stop(processesToStop)
        guard result.failed.isEmpty else {
            let rollback = system.resume(existing.union(result.applied))
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
        let identifier = app.bundleIdentifier
        let existing = backgroundedByTempra[identifier, default: []]
            .intersection(app.processIdentities)
        let result = system.setBackgroundPriority(app.processIdentities.subtracting(existing))
        guard result.failed.isEmpty else {
            let rollback = system.restorePriority(existing.union(result.applied))
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
        let identifier = app.bundleIdentifier
        let nowCPU = system.totalCPUTime(for: app.processIdentities)
        var runtime = limitRuntimes[identifier] ?? LimitRuntime(
            lastCPUNanoseconds: nowCPU,
            lastRunDuration: 0,
            estimatedFullSpeedCPU: max(app.cpuPercent, limitPercent, 1),
            cpuCreditNanoseconds: 0,
            generation: 0,
            phase: stoppedByTempra[identifier]?.isEmpty == false ? .stopped : .running,
            processIdentities: app.processIdentities
        )

        if runtime.processIdentities != app.processIdentities {
            runtime.lastCPUNanoseconds = nowCPU
            runtime.lastRunDuration = 0
            runtime.processIdentities = app.processIdentities
        } else if nowCPU >= runtime.lastCPUNanoseconds, runtime.lastRunDuration > 0 {
            let consumed = Double(nowCPU - runtime.lastCPUNanoseconds)
            let measuredFullSpeed = consumed / (runtime.lastRunDuration * 1_000_000_000) * 100
            if measuredFullSpeed > 0.5 {
                runtime.estimatedFullSpeedCPU = runtime.estimatedFullSpeedCPU * 0.65
                    + measuredFullSpeed * 0.35
            }
            runtime.cpuCreditNanoseconds -= consumed
        }

        let allowedCPU = controlInterval * max(0, limitPercent) / 100 * 1_000_000_000
        runtime.cpuCreditNanoseconds += allowedCPU

        let estimatedCPUPerWallSecond = max(runtime.estimatedFullSpeedCPU / 100, 0.01)
        let minimumSliceCost = minimumRunDuration
            * estimatedCPUPerWallSecond
            * 1_000_000_000
        let maximumCredit = max(allowedCPU, minimumSliceCost)
        let maximumDebt = max(limitPercent / 100 * 1_000_000_000, minimumSliceCost)
        runtime.cpuCreditNanoseconds = min(
            maximumCredit,
            max(-maximumDebt, runtime.cpuCreditNanoseconds)
        )

        let affordableRunDuration = max(0, runtime.cpuCreditNanoseconds)
            / (estimatedCPUPerWallSecond * 1_000_000_000)
        let runDuration = min(controlInterval, affordableRunDuration)
        runtime.lastCPUNanoseconds = nowCPU
        runtime.lastRunDuration = 0
        runtime.generation += 1
        let generation = runtime.generation
        limitRuntimes[identifier] = runtime
        limitStopDeadlines.remove(identifier: identifier)

        guard runDuration >= minimumRunDuration else {
            if runtime.phase == .stopped {
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

        runtime.lastCPUNanoseconds = system.totalCPUTime(for: app.processIdentities)
        runtime.lastRunDuration = runDuration
        runtime.phase = .running
        runtime.processIdentities = app.processIdentities

        guard runDuration < controlInterval * 0.98 else {
            limitRuntimes[identifier] = runtime
            await setStatus(.limited(limitPercent), for: identifier)
            return
        }

        let stopDeadline = clock.now().advanced(by: Self.duration(runDuration))
        limitRuntimes[identifier] = runtime
        limitStopDeadlines.upsert(LimitStopDeadline(
            identifier: identifier,
            deadline: stopDeadline,
            generation: generation,
            limitPercent: limitPercent,
            processIdentities: app.processIdentities
        ))
        await setStatus(.limited(limitPercent), for: identifier)
    }

    private func maintainLimitCycle(
        for app: ProcessControlTarget,
        limitPercent: Double
    ) async {
        let identifier = app.bundleIdentifier
        guard var runtime = limitRuntimes[identifier] else { return }

        if runtime.processIdentities != app.processIdentities {
            limitStopDeadlines.remove(identifier: identifier)
            runtime.lastCPUNanoseconds = system.totalCPUTime(for: app.processIdentities)
            runtime.lastRunDuration = 0
            runtime.generation += 1
            runtime.processIdentities = app.processIdentities
            limitRuntimes[identifier] = runtime
        }

        guard runtime.phase == .stopped else {
            await setStatus(.limited(limitPercent), for: identifier)
            return
        }

        guard await prepareWatchdogToStop(app.processIdentities, for: identifier) else {
            limitRuntimes.removeValue(forKey: identifier)
            return
        }
        let result = system.stop(app.processIdentities)
        guard result.failed.isEmpty else {
            let rollback = system.resume(result.applied)
            _ = await setStoppedProcesses(rollback.failed, for: identifier)
            let priorityRollback = system.restorePriority(
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
        await setStatus(.limited(limitPercent), for: identifier)
    }

    private func finishLimitCycle(
        identifier: String,
        generation: Int,
        limitPercent: Double,
        processIdentities: Set<ProcessIdentity>
    ) async {
        guard let runtime = limitRuntimes[identifier],
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
        guard !(await isFrontmost(app)) else { return }
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
        let result = system.stop(processIdentities)
        guard result.failed.isEmpty else {
            let rollback = system.resume(result.applied)
            _ = await setStoppedProcesses(rollback.failed, for: identifier)
            let priorityRollback = system.restorePriority(
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
        if var runtime = limitRuntimes[identifier], runtime.generation == generation {
            runtime.phase = .stopped
            runtime.processIdentities = currentApp.processIdentities
            limitRuntimes[identifier] = runtime
        }
        await setStatus(.limited(limitPercent), for: identifier)
        await updatePauseWakeMonitoring()
    }

    private func reconcileControlledProcesses() async {
        for identifier in Set(stoppedByTempra.keys).union(backgroundedByTempra.keys) {
            let current = groups[identifier]?.processIdentities ?? []

            let retiredStopped = stoppedByTempra[identifier, default: []].subtracting(current)
            if !retiredStopped.isEmpty {
                let result = system.resume(retiredStopped)
                let remaining = stoppedByTempra[identifier, default: []]
                    .subtracting(result.applied.union(result.stale))
                _ = await setStoppedProcesses(remaining, for: identifier)
            }

            let retiredBackgrounded = backgroundedByTempra[identifier, default: []]
                .subtracting(current)
            if !retiredBackgrounded.isEmpty {
                let result = system.restorePriority(retiredBackgrounded)
                backgroundedByTempra[identifier]?.subtract(result.applied.union(result.stale))
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
        let priorityRestored = await restoreBackgroundPriority(
            for: identifier,
            attempts: attempts
        )
        if resetDelay {
            backgroundSince.removeValue(forKey: identifier)
            hideRequested.remove(identifier)
            quitRequested.remove(identifier)
        }
        return resumed && priorityRestored
    }

    private func restoreProcessControl(identifier: String, attempts: Int) async -> Bool {
        let resumed = await restoreDisruptiveControl(identifier: identifier, attempts: attempts)
        let priorityRestored = await restoreBackgroundPriority(
            for: identifier,
            attempts: attempts
        )
        return resumed && priorityRestored
    }

    private func restoreDisruptiveControl(identifier: String, attempts: Int) async -> Bool {
        limitStopDeadlines.remove(identifier: identifier)
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
        let identifier = app.bundleIdentifier
        guard await restoreDisruptiveControl(
            identifier: identifier,
            attempts: restorationAttempts
        ) else {
            await markUnavailable(identifier, detail: "Tempra could not restore every process.")
            return false
        }

        if appliesEfficiencyCores, rule.runOnEfficiencyCores {
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
        return true
    }

    private func resumeStoppedProcesses(for identifier: String, attempts: Int) async -> Bool {
        let unresolved = await performWithRetries(
            stoppedByTempra[identifier, default: []],
            attempts: attempts,
            operation: system.resume
        )
        let synchronized = await setStoppedProcesses(unresolved, for: identifier)
        return unresolved.isEmpty && synchronized
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
        guard !processes.isEmpty else { return true }
        do {
            try await crashWatchdog.prepareToStop(processes)
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
            let emergencyResult = system.resume(pending)
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
        let identifiers = Set(stoppedByTempra.keys).union(backgroundedByTempra.keys)
        let failures = identifiers.compactMap { identifier -> ProcessRestorationFailure? in
            let stopped = stoppedByTempra[identifier, default: []]
            let backgrounded = backgroundedByTempra[identifier, default: []]
            guard !stopped.isEmpty || !backgrounded.isEmpty else { return nil }
            return ProcessRestorationFailure(
                bundleIdentifier: identifier,
                stoppedProcesses: stopped,
                backgroundPriorityProcesses: backgrounded
            )
        }.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        return ProcessRestorationResult(failures: failures)
    }

    private func restoreBackgroundPriority(for identifier: String, attempts: Int) async -> Bool {
        let unresolved = await performWithRetries(
            backgroundedByTempra[identifier, default: []],
            attempts: attempts,
            operation: system.restorePriority
        )
        if unresolved.isEmpty {
            backgroundedByTempra.removeValue(forKey: identifier)
            return true
        }
        backgroundedByTempra[identifier] = unresolved
        return false
    }

    private func performWithRetries(
        _ processes: Set<ProcessIdentity>,
        attempts: Int,
        operation: (Set<ProcessIdentity>) -> ProcessOperationResult
    ) async -> Set<ProcessIdentity> {
        var unresolved = processes
        guard !unresolved.isEmpty else { return [] }

        for attempt in 0..<max(1, attempts) {
            let result = operation(unresolved)
            unresolved = result.failed
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

    private func setStatus(_ status: ManagementStatus, for identifier: String) async {
        let previous = statuses[identifier] ?? .normal
        statuses[identifier] = status
        guard previous != status else { return }
        await eventHandler?(.statusTransition(
            bundleIdentifier: identifier,
            previous: previous,
            current: status
        ))
    }

    private func markUnavailable(_ identifier: String, detail: String) async {
        let shouldRecord = statuses[identifier] != .unavailable
        await setStatus(.unavailable, for: identifier)
        if shouldRecord {
            await emitActivity(identifier, kind: .error, detail: detail)
        }
    }

    private func emitActivity(_ identifier: String, kind: ActivityKind, detail: String) async {
        await eventHandler?(.activity(
            bundleIdentifier: identifier,
            kind: kind,
            detail: detail
        ))
    }

    private func updatePauseWakeMonitoring() async {
        let needsMonitoring = stoppedByTempra.contains { identifier, processes in
            !processes.isEmpty && rules[identifier]?.action == .pause
        }
        guard needsMonitoring != isPauseWakeMonitoringEnabled else { return }
        isPauseWakeMonitoringEnabled = needsMonitoring
        await eventHandler?(.pauseWakeMonitoringChanged(needsMonitoring))
    }

    private func scheduleLimitStopScheduler() {
        guard isEnabled, let nextDeadline = limitStopDeadlines.first else {
            limitStopSchedulerTask?.cancel()
            limitStopSchedulerTask = nil
            scheduledLimitStopDeadline = nil
            limitStopSchedulerGeneration &+= 1
            return
        }

        if limitStopSchedulerTask != nil,
           scheduledLimitStopDeadline == nextDeadline.deadline {
            return
        }

        limitStopSchedulerTask?.cancel()
        limitStopSchedulerGeneration &+= 1
        let schedulerGeneration = limitStopSchedulerGeneration
        let deadline = nextDeadline.deadline
        scheduledLimitStopDeadline = deadline
        limitStopSchedulerTask = Task { [weak self, clock] in
            var nextDeadline = deadline
            while !Task.isCancelled {
                await clock.sleepUntil(nextDeadline)
                guard !Task.isCancelled else { return }
                guard let followingDeadline = await self?.processLimitStopDeadlines(
                    schedulerGeneration: schedulerGeneration
                ) else {
                    return
                }
                nextDeadline = followingDeadline
            }
        }
    }

    private func processLimitStopDeadlines(
        schedulerGeneration: UInt64
    ) async -> ContinuousClock.Instant? {
        guard schedulerGeneration == limitStopSchedulerGeneration else { return nil }
        let now = clock.now()
        var dueDeadlines: [LimitStopDeadline] = []
        while let nextDeadline = limitStopDeadlines.first,
              nextDeadline.deadline <= now,
              let deadline = limitStopDeadlines.popFirst() {
            dueDeadlines.append(deadline)
        }

        for deadline in dueDeadlines {
            await finishLimitCycle(
                identifier: deadline.identifier,
                generation: deadline.generation,
                limitPercent: deadline.limitPercent,
                processIdentities: deadline.processIdentities
            )
        }

        guard schedulerGeneration == limitStopSchedulerGeneration else { return nil }
        guard let nextDeadline = limitStopDeadlines.first?.deadline else {
            limitStopSchedulerTask = nil
            scheduledLimitStopDeadline = nil
            return nil
        }
        scheduledLimitStopDeadline = nextDeadline
        return nextDeadline
    }

    private func resetLimitStopScheduler() {
        limitStopSchedulerTask?.cancel()
        limitStopSchedulerTask = nil
        scheduledLimitStopDeadline = nil
        limitStopSchedulerGeneration &+= 1
        limitStopDeadlines.removeAll()
    }

    private func scheduleNextTick(now: Date = Date()) {
        guard isEnabled else { return }
        var nextInterval: TimeInterval?
        func include(_ interval: TimeInterval) {
            let normalized = max(0.001, interval)
            nextInterval = min(nextInterval ?? normalized, normalized)
        }

        for app in groups.values {
            let identifier = app.bundleIdentifier
            guard let rule = rules[identifier],
                  rule.hasBehavior,
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
            } else if rule.action == .limit {
                include(controlInterval)
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
        let proposedDeadline = clockNow.advanced(by: Self.duration(nextInterval))
        if tickTask != nil,
           let scheduledTickDeadline,
           scheduledTickDeadline <= proposedDeadline {
            scheduledTickInterval = max(
                0,
                Self.timeInterval(clockNow.duration(to: scheduledTickDeadline))
            )
            return
        }

        tickTask?.cancel()
        scheduledTickInterval = nextInterval
        scheduledTickDeadline = proposedDeadline
        tickTask = Task { [weak self, clock] in
            await clock.sleepUntil(proposedDeadline)
            guard !Task.isCancelled else { return }
            await self?.tick(trigger: .cadence)
        }
    }

    private func refreshWindowVisibility() {
        let snapshot = windowSnapshotProvider()
        for identifier in groups.keys {
            guard var app = groups[identifier] else { continue }
            app.windowVisibility = snapshot?.visibility(
                for: Set(app.processIdentities.map(\.pid)),
                isHidden: false
            ) ?? .unknown
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

    private static func duration(_ interval: TimeInterval) -> Duration {
        .nanoseconds(Int64(max(0, interval) * 1_000_000_000))
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
