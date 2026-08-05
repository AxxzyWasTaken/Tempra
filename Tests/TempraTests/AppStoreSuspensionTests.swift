import Foundation
import Testing
@testable import Tempra

@Suite("App store suspensions")
@MainActor
struct AppStoreSuspensionTests {
    @Test("A snoozed rule resumes at its deadline without another monitoring event")
    func snoozeExpiresWithoutMonitoringEvent() async throws {
        try await withDefaults { defaults in
            let identifier = "example.snoozed"
            let persistence = AppPersistence(defaults: defaults)
            try persistence.saveRules([identifier: AppRule(
                bundleIdentifier: identifier,
                displayName: "Example",
                action: .pause,
                delaySeconds: 60
            )])
            let clock = ManualSuspensionExpirationClock(now: Date())
            let coordinator = ProcessManagementCoordinator(
                controller: ProcessController(
                    frontmostProvider: { nil },
                    windowSnapshotProvider: {
                        WindowVisibilitySnapshot(windowsFrontToBack: [], screenBounds: [])
                    }
                ),
                processWatcher: ManagedProcessWatcher(
                    audioMonitor: SuspensionTestAudioMonitor()
                )
            )
            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: coordinator,
                monitoringService: SuspensionTestMonitoringService(),
                launchAtLoginController: SuspensionTestLaunchAtLoginController(),
                startsMonitoring: false,
                suspensionClock: clock.clock,
                persistenceErrorHandler: { _ in }
            )
            store.applyMonitoringSample(
                MonitoringSample(
                    generation: 1,
                    systemCPU: nil,
                    apps: [ManagedApp(
                        bundleIdentifier: identifier,
                        name: "Example",
                        bundleURL: nil,
                        processIdentifiers: [],
                        launchedAt: Date().addingTimeInterval(-120),
                        cpuPercent: 10,
                        isFrontmost: false,
                        isHidden: true,
                        isPlayingAudio: false,
                        isSystemProcess: false,
                        windowVisibility: .hiddenOrMinimized,
                        status: .normal
                    )],
                    didRefreshApplications: true,
                    powerByIdentifier: [:],
                    powerMetricsSupported: false
                ),
                demand: .dormant
            )
            #expect(await eventually {
                coordinator.statuses[identifier] == .waiting
            })

            store.snooze(bundleIdentifier: identifier, for: 60)
            #expect(await eventually {
                coordinator.statuses[identifier] == nil
            })
            #expect(await eventually { clock.pendingSleepCount == 1 })

            clock.advance(by: 59)
            #expect(store.suspensions[identifier] != nil)
            #expect(coordinator.statuses[identifier] == nil)

            clock.advance(by: 1)
            #expect(await eventually {
                store.suspensions[identifier] == nil
                    && coordinator.statuses[identifier] == .waiting
            })
            #expect(try persistence.loadSuspensions().isEmpty)

            _ = await store.shutdown()
        }
    }

    @Test("Suspension scheduling keeps one task and advances to the next deadline")
    func multipleSnoozesUseOneScheduledTask() async throws {
        try await withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)
            let clock = ManualSuspensionExpirationClock(now: Date())
            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: ProcessManagementCoordinator(
                    controller: ProcessController(frontmostProvider: { nil }),
                    processWatcher: ManagedProcessWatcher(
                        audioMonitor: SuspensionTestAudioMonitor()
                    )
                ),
                monitoringService: SuspensionTestMonitoringService(),
                launchAtLoginController: SuspensionTestLaunchAtLoginController(),
                startsMonitoring: false,
                suspensionClock: clock.clock,
                persistenceErrorHandler: { _ in }
            )

            store.snooze(bundleIdentifier: "first.app", for: 60)
            store.snooze(bundleIdentifier: "second.app", for: 120)
            #expect(await eventually { clock.pendingSleepCount == 1 })

            clock.advance(by: 60)
            #expect(await eventually {
                store.suspensions["first.app"] == nil
                    && store.suspensions["second.app"] != nil
                    && clock.pendingSleepCount == 1
            })

            clock.advance(by: 60)
            #expect(await eventually {
                store.suspensions.isEmpty && clock.pendingSleepCount == 0
            })
            #expect(try persistence.loadSuspensions().isEmpty)

            _ = await store.shutdown()
        }
    }

    @Test("A persisted suspension schedules its expiration during initialization")
    func persistedSuspensionSchedulesAtInitialization() async throws {
        try await withDefaults { defaults in
            let identifier = "persisted.app"
            let now = Date()
            let persistence = AppPersistence(defaults: defaults)
            try persistence.saveSuspensions([identifier: RuleSuspension(
                bundleIdentifier: identifier,
                until: now.addingTimeInterval(60)
            )])
            let clock = ManualSuspensionExpirationClock(now: now)
            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: ProcessManagementCoordinator(
                    controller: ProcessController(frontmostProvider: { nil }),
                    processWatcher: ManagedProcessWatcher(
                        audioMonitor: SuspensionTestAudioMonitor()
                    )
                ),
                monitoringService: SuspensionTestMonitoringService(),
                launchAtLoginController: SuspensionTestLaunchAtLoginController(),
                startsMonitoring: false,
                suspensionClock: clock.clock,
                persistenceErrorHandler: { _ in }
            )

            #expect(await eventually { clock.pendingSleepCount == 1 })
            clock.advance(by: 60)
            #expect(await eventually {
                store.suspensions.isEmpty && clock.pendingSleepCount == 0
            })
            #expect(try persistence.loadSuspensions().isEmpty)

            _ = await store.shutdown()
        }
    }

    @Test("A global management pause restores rules and reapplies them at its deadline")
    func globalPauseExpiresWithoutMonitoringEvent() async throws {
        try await withDefaults { defaults in
            let identifier = "example.global-pause"
            let persistence = AppPersistence(defaults: defaults)
            try persistence.saveRules([identifier: AppRule(
                bundleIdentifier: identifier,
                displayName: "Example",
                action: .pause,
                delaySeconds: 60
            )])
            let clock = ManualSuspensionExpirationClock(now: Date())
            let coordinator = ProcessManagementCoordinator(
                controller: ProcessController(
                    frontmostProvider: { nil },
                    windowSnapshotProvider: {
                        WindowVisibilitySnapshot(windowsFrontToBack: [], screenBounds: [])
                    }
                ),
                processWatcher: ManagedProcessWatcher(
                    audioMonitor: SuspensionTestAudioMonitor()
                )
            )
            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: coordinator,
                monitoringService: SuspensionTestMonitoringService(),
                launchAtLoginController: SuspensionTestLaunchAtLoginController(),
                startsMonitoring: false,
                suspensionClock: clock.clock,
                userIdleMonitor: UserIdleMonitor(secondsProvider: { 0 }),
                persistenceErrorHandler: { _ in }
            )
            store.applyMonitoringSample(
                MonitoringSample(
                    generation: 1,
                    systemCPU: nil,
                    apps: [ManagedApp(
                        bundleIdentifier: identifier,
                        name: "Example",
                        bundleURL: nil,
                        processIdentifiers: [],
                        launchedAt: Date().addingTimeInterval(-120),
                        cpuPercent: 10,
                        isFrontmost: false,
                        isHidden: true,
                        isPlayingAudio: false,
                        isSystemProcess: false,
                        windowVisibility: .hiddenOrMinimized,
                        status: .normal
                    )],
                    didRefreshApplications: true,
                    powerByIdentifier: [:],
                    powerMetricsSupported: false
                ),
                demand: .dormant
            )
            #expect(await eventually { coordinator.statuses[identifier] == .waiting })

            store.pauseManagement(for: 60)
            #expect(store.isManagementPaused)
            #expect(await eventually { coordinator.statuses[identifier] == nil })
            #expect(try persistence.loadPreferences().managementPauseUntil != nil)

            clock.advance(by: 60)
            #expect(await eventually {
                !store.isManagementPaused && coordinator.statuses[identifier] == .waiting
            })
            #expect(try persistence.loadPreferences().managementPauseUntil == nil)

            _ = await store.shutdown()
        }
    }

    @Test("Lifecycle holds reapply rules only after every hold and the wake grace")
    func lifecycleHoldsUseWakeGrace() async throws {
        try await withDefaults { defaults in
            let identifier = "example.lifecycle"
            let persistence = AppPersistence(defaults: defaults)
            try persistence.saveRules([identifier: AppRule(
                bundleIdentifier: identifier,
                displayName: "Example",
                action: .pause,
                delaySeconds: 60
            )])
            let clock = ManualSuspensionExpirationClock(now: Date())
            let coordinator = ProcessManagementCoordinator(
                controller: ProcessController(
                    frontmostProvider: { nil },
                    windowSnapshotProvider: {
                        WindowVisibilitySnapshot(windowsFrontToBack: [], screenBounds: [])
                    }
                ),
                processWatcher: ManagedProcessWatcher(
                    audioMonitor: SuspensionTestAudioMonitor()
                )
            )
            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: coordinator,
                monitoringService: SuspensionTestMonitoringService(),
                launchAtLoginController: SuspensionTestLaunchAtLoginController(),
                startsMonitoring: false,
                suspensionClock: clock.clock,
                userIdleMonitor: UserIdleMonitor(secondsProvider: { 0 }),
                persistenceErrorHandler: { _ in }
            )
            store.applyMonitoringSample(
                MonitoringSample(
                    generation: 1,
                    systemCPU: nil,
                    apps: [ManagedApp(
                        bundleIdentifier: identifier,
                        name: "Example",
                        bundleURL: nil,
                        processIdentifiers: [],
                        launchedAt: Date().addingTimeInterval(-120),
                        cpuPercent: 10,
                        isFrontmost: false,
                        isHidden: true,
                        isPlayingAudio: false,
                        isSystemProcess: false,
                        windowVisibility: .hiddenOrMinimized,
                        status: .normal
                    )],
                    didRefreshApplications: true,
                    powerByIdentifier: [:],
                    powerMetricsSupported: false
                ),
                demand: .dormant
            )
            #expect(await eventually { coordinator.statuses[identifier] == .waiting })

            await store.suspendManagement(for: .systemSleep)
            await store.suspendManagement(for: .inactiveUserSession)
            #expect(await eventually { coordinator.statuses[identifier] == nil })

            store.resumeManagement(after: .systemSleep)
            #expect(clock.pendingSleepCount == 0)
            store.resumeManagement(after: .inactiveUserSession)
            #expect(await eventually { clock.pendingSleepCount == 1 })

            clock.advance(by: 4)
            #expect(coordinator.statuses[identifier] == nil)
            clock.advance(by: 1)
            #expect(await eventually { coordinator.statuses[identifier] == .waiting })

            _ = await store.shutdown()
        }
    }

    private func eventually(
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func withDefaults(
        _ operation: (UserDefaults) async throws -> Void
    ) async throws {
        let suiteName = "TempraSuspensionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await operation(defaults)
    }
}

private final class ManualSuspensionExpirationClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var currentDate: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []

    init(now: Date) {
        currentDate = now
    }

    var clock: SuspensionExpirationClock {
        SuspensionExpirationClock(
            now: { [self] in now },
            sleepUntil: { [self] deadline in await sleep(until: deadline) }
        )
    }

    var now: Date {
        withLock { currentDate }
    }

    var pendingSleepCount: Int {
        withLock { sleepers.count }
    }

    func advance(by interval: TimeInterval) {
        let continuations: [CheckedContinuation<Bool, Never>] = withLock {
            currentDate = currentDate.addingTimeInterval(interval)
            let dueIDs = sleepers.compactMap { id, sleeper in
                sleeper.deadline <= currentDate ? id : nil
            }
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        }
        continuations.forEach { $0.resume(returning: true) }
    }

    private func sleep(until deadline: Date) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let reachedDeadline: Bool? = withLock {
                    if cancelledBeforeRegistration.remove(id) != nil {
                        return false
                    }
                    if deadline <= currentDate {
                        return true
                    }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let reachedDeadline {
                    continuation.resume(returning: reachedDeadline)
                }
            }
        } onCancel: {
            cancelSleep(id: id)
        }
    }

    private func cancelSleep(id: UUID) {
        let continuation: CheckedContinuation<Bool, Never>? = withLock {
            if let sleeper = sleepers.removeValue(forKey: id) {
                return sleeper.continuation
            }
            cancelledBeforeRegistration.insert(id)
            return nil
        }
        continuation?.resume(returning: false)
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private actor SuspensionTestAudioMonitor: AudioActivityMonitoring {
    func watch(
        revision: UInt64,
        processIdentifiers: Set<pid_t>,
        onActivityChange: @escaping ActivityHandler
    ) {}

    func stop(revision: UInt64) {}
}

private actor SuspensionTestMonitoringService: MonitoringServicing {
    func sample(_ request: MonitoringRequest) -> MonitoringSample {
        MonitoringSample(
            generation: request.generation,
            systemCPU: nil,
            apps: nil,
            didRefreshApplications: false,
            powerByIdentifier: [:],
            powerMetricsSupported: false
        )
    }

    func resetApplicationBaseline() {}
    func resetPowerMetrics() {}
    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {}
    func shutdown() {}
}

@MainActor
private final class SuspensionTestLaunchAtLoginController: LaunchAtLoginControlling {
    var isEnabled = false
    var requiresApproval = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}
