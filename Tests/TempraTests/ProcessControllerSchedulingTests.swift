import Foundation
import Testing
@testable import Tempra

@Suite("Process controller scheduling")
@MainActor
struct ProcessControllerSchedulingTests {
    private let identifier = "example.app"

    private func target(
        identifier: String? = nil,
        processIdentities: Set<ProcessIdentity> = [],
        launchedAt: Date? = nil,
        cpuPercent: Double = 50,
        isFrontmost: Bool = false,
        isHidden: Bool = true,
        isPlayingAudio: Bool = false,
        isProtectedByMenuBarOverlay: Bool = false,
        windowVisibility: AppWindowVisibility = .hiddenOrMinimized
    ) -> ProcessControlTarget {
        ProcessControlTarget(
            bundleIdentifier: identifier ?? self.identifier,
            processIdentities: processIdentities,
            launchedAt: launchedAt,
            cpuPercent: cpuPercent,
            isFrontmost: isFrontmost,
            isHidden: isHidden,
            isPlayingAudio: isPlayingAudio,
            windowVisibility: windowVisibility,
            isProtectedByMenuBarOverlay: isProtectedByMenuBarOverlay
        )
    }

    @Test("No rules leave the control scheduler dormant")
    func noRulesAreDormant() async {
        let controller = ProcessController()
        let snapshot = await controller.update(
            targets: [target()],
            rules: [:],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.scheduledTickInterval == nil)
        await controller.shutdown()
    }

    @Test("A delayed rule keeps the visibility watch active")
    func delayedRuleSchedulesDeadline() async {
        let controller = ProcessController()
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 300
        )
        let snapshot = await controller.update(
            targets: [target()],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect((snapshot.scheduledTickInterval ?? 0) > 0.9)
        #expect((snapshot.scheduledTickInterval ?? 2) <= 1)
        await controller.shutdown()
    }

    @Test("A newly launched app waits for the launch grace period")
    func recentLaunchSchedulesGraceDeadline() async {
        let controller = ProcessController()
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 0
        )
        let snapshot = await controller.update(
            targets: [target(launchedAt: Date())],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .waiting)
        #expect((snapshot.scheduledTickInterval ?? 0) > 59)
        #expect((snapshot.scheduledTickInterval ?? 61) <= ProcessController.launchGracePeriod)
        await controller.shutdown()
    }

    @Test("An app older than the launch grace period can be limited")
    func oldLaunchEnablesControlCadence() async {
        let controller = ProcessController()
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 0
        )
        let snapshot = await controller.update(
            targets: [target(launchedAt: Date().addingTimeInterval(-61))],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .limited(50))
        #expect(snapshot.scheduledTickInterval == 0.5)
        await controller.shutdown()
    }

    @Test("Power-saving-core scheduling also respects launch grace")
    func recentLaunchDefersEfficiencyScheduling() async {
        let controller = ProcessController()
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            runOnEfficiencyCores: true
        )
        let snapshot = await controller.update(
            targets: [target(launchedAt: Date())],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .waiting)
        #expect((snapshot.scheduledTickInterval ?? 0) > 59)
        await controller.shutdown()
    }

    @Test("Menu-bar overlay protection does not bypass launch grace")
    func overlayProtectionRespectsLaunchGrace() async {
        let controller = ProcessController()
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            runOnEfficiencyCores: true
        )
        let snapshot = await controller.update(
            targets: [target(
                launchedAt: Date(),
                isProtectedByMenuBarOverlay: true
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .waiting)
        await controller.shutdown()
    }

    @Test("A visible app is not CPU limited")
    func visibleAppDefersLimit() async {
        let controller = ProcessController()
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 0
        )
        let snapshot = await controller.update(
            targets: [target(
                launchedAt: Date().addingTimeInterval(-61),
                windowVisibility: .visible
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .waiting)
        #expect((snapshot.scheduledTickInterval ?? 0) > 0.9)
        #expect((snapshot.scheduledTickInterval ?? 2) <= 1)
        await controller.shutdown()
    }

    @Test("Becoming visible releases active CPU control")
    func becomingVisibleReleasesControl() async {
        let controller = ProcessController()
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 0
        )
        let launchedAt = Date().addingTimeInterval(-61)
        let limited = await controller.update(
            targets: [target(launchedAt: launchedAt)],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        let visible = await controller.update(
            targets: [target(
                launchedAt: launchedAt,
                windowVisibility: .visible
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 2
        )

        #expect(limited.statuses[identifier] == .limited(50))
        #expect(visible.statuses[identifier] == .waiting)
        await controller.shutdown()
    }

    @Test("Visibility recheck releases active CPU control")
    func visibilityRecheckReleasesControl() async {
        let controller = ProcessController(windowSnapshotProvider: { nil })
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 0
        )
        let limited = await controller.update(
            targets: [target(launchedAt: Date().addingTimeInterval(-61))],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        try? await Task.sleep(for: .milliseconds(700))
        let protected = await controller.currentSnapshot()

        #expect(limited.statuses[identifier] == .limited(50))
        #expect(protected.statuses[identifier] == .waiting)
        await controller.shutdown()
    }

    @Test("Unknown window visibility is protected")
    func unknownVisibilityDefersEfficiencyScheduling() async {
        let controller = ProcessController()
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            runOnEfficiencyCores: true
        )
        let snapshot = await controller.update(
            targets: [target(
                launchedAt: Date().addingTimeInterval(-61),
                windowVisibility: .unknown
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .waiting)
        #expect((snapshot.scheduledTickInterval ?? 0) > 0.9)
        #expect((snapshot.scheduledTickInterval ?? 2) <= 1)
        await controller.shutdown()
    }

    @Test("A visible app is not moved to power-saving cores")
    func visibleAppDefersEfficiencyScheduling() async {
        let controller = ProcessController()
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            runOnEfficiencyCores: true
        )
        let snapshot = await controller.update(
            targets: [target(
                launchedAt: Date().addingTimeInterval(-61),
                windowVisibility: .visible
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .waiting)
        #expect((snapshot.scheduledTickInterval ?? 0) > 0.9)
        #expect((snapshot.scheduledTickInterval ?? 2) <= 1)
        await controller.shutdown()
    }

    @Test("A fully covered app remains eligible for management")
    func coveredAppSchedulesControl() async {
        let controller = ProcessController()
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 0
        )
        let snapshot = await controller.update(
            targets: [target(
                launchedAt: Date().addingTimeInterval(-61),
                windowVisibility: .covered
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .waiting)
        #expect((snapshot.scheduledTickInterval ?? 0) > 0.9)
        #expect((snapshot.scheduledTickInterval ?? 2) <= 1)
        await controller.shutdown()
    }

    @Test("Equal limit deadlines share one timer wake")
    func equalLimitDeadlinesShareTimerWake() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let identifiers = (0..<8).map { "example.app.\($0)" }
        let targets = identifiers.enumerated().map { index, identifier in
            target(
                identifier: identifier,
                processIdentities: [ProcessIdentity(
                    pid: pid_t(10_000 + index),
                    startTimeMicroseconds: UInt64(index + 1)
                )],
                launchedAt: Date().addingTimeInterval(-61),
                cpuPercent: 100
            )
        }
        let rules = Dictionary(uniqueKeysWithValues: identifiers.map { identifier in
            (identifier, AppRule(
                bundleIdentifier: identifier,
                displayName: identifier,
                action: .limit,
                limitPercent: 10
            ))
        })
        let controller = ProcessController(
            system: system,
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: targets,
            rules: rules,
            isEnabled: true,
            revision: 1
        )

        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        #expect(manualClock.sleepRegistrationCount == 2)

        manualClock.advance(by: .milliseconds(50))
        #expect(await eventually { system.stopAttemptCount == identifiers.count })
        #expect(manualClock.deadlineWakeCount == 1)
        await controller.shutdown()
    }

    @Test("Different limit deadlines use the same ordered scheduler")
    func differentLimitDeadlinesFireInOrder() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let firstIdentifier = "example.app.first"
        let secondIdentifier = "example.app.second"
        let firstProcess = process(1)
        let secondProcess = process(2)
        let rules = [
            firstIdentifier: limitRule(firstIdentifier),
            secondIdentifier: limitRule(secondIdentifier)
        ]
        let controller = ProcessController(
            system: system,
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [
                target(
                    identifier: firstIdentifier,
                    processIdentities: [firstProcess],
                    launchedAt: oldLaunchDate,
                    cpuPercent: 100
                ),
                target(
                    identifier: secondIdentifier,
                    processIdentities: [secondProcess],
                    launchedAt: oldLaunchDate,
                    cpuPercent: 50
                )
            ],
            rules: rules,
            isEnabled: true,
            revision: 1
        )

        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        manualClock.advance(by: .milliseconds(50))
        #expect(await eventually { system.didAttemptToStop(firstProcess) })
        #expect(!system.didAttemptToStop(secondProcess))
        #expect(await eventually { manualClock.sleepRegistrationCount == 3 })

        manualClock.advance(by: .milliseconds(49))
        #expect(!system.didAttemptToStop(secondProcess))
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToStop(secondProcess) })
        #expect(manualClock.deadlineWakeCount == 2)
        await controller.shutdown()
    }

    @Test("Replacing a rule cancels its previous deadline")
    func ruleReplacementCancelsPreviousDeadline() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(3)
        let controller = ProcessController(
            system: system,
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 10)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 20)],
            isEnabled: true,
            revision: 2
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        manualClock.advance(by: .milliseconds(50))
        #expect(!system.didAttemptToStop(controlledProcess))
        manualClock.advance(by: .milliseconds(50))
        #expect(await eventually { system.didAttemptToStop(controlledProcess) })
        await controller.shutdown()
    }

    @Test("Removing a rule cancels its pending deadline")
    func removingRuleCancelsPendingDeadline() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(4)
        let controlledTarget = target(
            processIdentities: [controlledProcess],
            launchedAt: oldLaunchDate,
            cpuPercent: 100
        )
        let controller = ProcessController(
            system: system,
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [controlledTarget],
            rules: [identifier: limitRule(identifier)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        _ = await controller.update(
            targets: [controlledTarget],
            rules: [:],
            isEnabled: true,
            revision: 2
        )

        #expect(await eventually { manualClock.pendingSleepCount == 0 })
        manualClock.advance(by: .milliseconds(500))
        #expect(system.stopAttemptCount == 0)
        #expect(manualClock.deadlineWakeCount == 0)
        await controller.shutdown()
    }

    @Test("Process exit removes its pending deadline")
    func processExitRemovesPendingDeadline() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let exitedProcess = process(5)
        let rule = limitRule(identifier)
        let controller = ProcessController(
            system: system,
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [exitedProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        _ = await controller.update(
            targets: [],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 2
        )

        #expect(await eventually { manualClock.pendingSleepCount == 0 })
        manualClock.advance(by: .milliseconds(500))
        #expect(!system.didAttemptToStop(exitedProcess))
        await controller.shutdown()
    }

    @Test("Visibility protection cancels a pending limit stop")
    func visibilityProtectionCancelsPendingStop() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(6)
        let rule = limitRule(identifier)
        let controller = ProcessController(
            system: system,
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        let protected = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100,
                windowVisibility: .visible
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 2
        )

        manualClock.advance(by: .milliseconds(50))
        #expect(protected.statuses[identifier] == .waiting)
        #expect(!system.didAttemptToStop(controlledProcess))
        await controller.shutdown()
    }

    @Test("Audio and frontmost protection cancel pending limit stops", arguments: [true, false])
    func activeProtectionCancelsPendingStop(useAudioProtection: Bool) async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(useAudioProtection ? 7 : 8)
        let rule = limitRule(identifier)
        let controller = ProcessController(
            system: system,
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        let protected = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100,
                isFrontmost: !useAudioProtection,
                isPlayingAudio: useAudioProtection
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 2
        )

        manualClock.advance(by: .milliseconds(50))
        let expectedStatus: ManagementStatus = useAudioProtection ? .audioProtected : .normal
        #expect(protected.statuses[identifier] == expectedStatus)
        #expect(!system.didAttemptToStop(controlledProcess))
        await controller.shutdown()
    }

    @Test("Shutdown restores a process stopped by the deadline scheduler")
    func shutdownRestoresStoppedProcess() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(9)
        let controller = ProcessController(
            system: system,
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100
            )],
            rules: [identifier: limitRule(identifier)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        manualClock.advance(by: .milliseconds(50))
        #expect(await eventually { system.didAttemptToStop(controlledProcess) })

        await controller.shutdown()
        #expect(system.didAttemptToResume(controlledProcess))
        #expect(await eventually { manualClock.pendingSleepCount == 0 })
    }

    @Test("Stale scheduler generations cannot stop a replacement process")
    func staleGenerationDoesNotStopReplacementProcess() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let oldProcess = process(10)
        let replacementProcess = ProcessIdentity(
            pid: oldProcess.pid,
            startTimeMicroseconds: oldProcess.startTimeMicroseconds + 1
        )
        let rule = limitRule(identifier)
        let controller = ProcessController(
            system: system,
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [oldProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        _ = await controller.update(
            targets: [target(
                processIdentities: [oldProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100,
                windowVisibility: .visible
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 2
        )
        _ = await controller.update(
            targets: [target(
                processIdentities: [replacementProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 50
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 3
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        manualClock.advance(by: .milliseconds(50))
        #expect(!system.didAttemptToStop(oldProcess))
        #expect(!system.didAttemptToStop(replacementProcess))
        manualClock.advance(by: .milliseconds(50))
        #expect(await eventually { system.didAttemptToStop(replacementProcess) })
        #expect(!system.didAttemptToStop(oldProcess))
        await controller.shutdown()
    }

    @Test("Minimum run duration remains enforced")
    func minimumRunDurationIsEnforced() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(11)
        let controller = ProcessController(
            system: system,
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 1)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })

        manualClock.advance(by: .milliseconds(4))
        #expect(system.stopAttemptCount == 0)
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.stopAttemptCount == 1 })
        await controller.shutdown()
    }

    @Test("A failed stop is retried on the next control cadence")
    func failedStopRetriesOnControlCadence() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(12)
        system.failNextStop(for: controlledProcess)
        let hiddenSnapshot = WindowVisibilitySnapshot(windowsFrontToBack: [], screenBounds: [])
        let controller = ProcessController(
            system: system,
            windowSnapshotProvider: { hiddenSnapshot },
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100
            )],
            rules: [identifier: limitRule(identifier)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        manualClock.advance(by: .milliseconds(50))
        #expect(await eventually { system.stopAttemptCount == 1 })
        let failed = await controller.currentSnapshot()
        #expect(failed.statuses[identifier] == .unavailable)

        manualClock.advance(by: .milliseconds(450))
        #expect(await eventually { manualClock.sleepRegistrationCount >= 4 })
        manualClock.advance(by: .milliseconds(50))
        #expect(await eventually { system.stopAttemptCount == 2 })
        let recovered = await controller.currentSnapshot()
        #expect(recovered.statuses[identifier] == .limited(10))
        await controller.shutdown()
    }

    private var oldLaunchDate: Date {
        Date().addingTimeInterval(-61)
    }

    private func process(_ index: Int) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid_t(20_000 + index),
            startTimeMicroseconds: UInt64(index + 1)
        )
    }

    private func limitRule(
        _ identifier: String,
        limitPercent: Double = 10
    ) -> AppRule {
        AppRule(
            bundleIdentifier: identifier,
            displayName: identifier,
            action: .limit,
            limitPercent: limitPercent
        )
    }

    private func eventually(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private final class RecordingProcessSystem: ProcessSystemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var stopAttempts: [Set<ProcessIdentity>] = []
    private var resumeAttempts: [Set<ProcessIdentity>] = []
    private var stopFailuresRemaining: [ProcessIdentity: Int] = [:]

    var stopAttemptCount: Int {
        withLock { stopAttempts.count }
    }

    func didAttemptToStop(_ process: ProcessIdentity) -> Bool {
        withLock { stopAttempts.contains { $0.contains(process) } }
    }

    func didAttemptToResume(_ process: ProcessIdentity) -> Bool {
        withLock { resumeAttempts.contains { $0.contains(process) } }
    }

    func failNextStop(for process: ProcessIdentity) {
        withLock {
            stopFailuresRemaining[process, default: 0] += 1
        }
    }

    func totalCPUTime(for processes: Set<ProcessIdentity>) -> UInt64 {
        0
    }

    func stop(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        withLock {
            stopAttempts.append(processes)
            var result = ProcessOperationResult()
            for process in processes {
                let failures = stopFailuresRemaining[process, default: 0]
                if failures > 0 {
                    stopFailuresRemaining[process] = failures - 1
                    result.failed.insert(process)
                } else {
                    result.applied.insert(process)
                }
            }
            return result
        }
    }

    func resume(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        withLock {
            resumeAttempts.append(processes)
            return ProcessOperationResult(applied: processes)
        }
    }

    func setBackgroundPriority(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        ProcessOperationResult(applied: processes)
    }

    func restorePriority(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        ProcessOperationResult(applied: processes)
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class ManualProcessControlClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var currentInstant = ContinuousClock().now
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var registrationCount = 0
    private var wakeCount = 0

    var clock: ProcessControlClock {
        ProcessControlClock(
            now: { [self] in now },
            sleepUntil: { [self] deadline in
                await sleep(until: deadline)
            }
        )
    }

    var now: ContinuousClock.Instant {
        withLock { currentInstant }
    }

    var sleepRegistrationCount: Int {
        withLock { registrationCount }
    }

    var deadlineWakeCount: Int {
        withLock { wakeCount }
    }

    var pendingSleepCount: Int {
        withLock { sleepers.count }
    }

    func advance(by duration: Duration) {
        let continuations: [CheckedContinuation<Void, Never>] = withLock {
            currentInstant = currentInstant.advanced(by: duration)
            let dueIDs = sleepers.compactMap { id, sleeper in
                sleeper.deadline <= currentInstant ? id : nil
            }
            wakeCount += dueIDs.count
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        }
        continuations.forEach { $0.resume() }
    }

    private func sleep(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = withLock {
                    registrationCount += 1
                    if cancelledBeforeRegistration.remove(id) != nil || deadline <= currentInstant {
                        return true
                    }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            cancelSleep(id: id)
        }
    }

    private func cancelSleep(id: UUID) {
        let continuation: CheckedContinuation<Void, Never>? = withLock {
            if let sleeper = sleepers.removeValue(forKey: id) {
                return sleeper.continuation
            }
            cancelledBeforeRegistration.insert(id)
            return nil
        }
        continuation?.resume()
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
