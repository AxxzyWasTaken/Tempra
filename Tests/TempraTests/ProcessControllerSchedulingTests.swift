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
        processSamples: [ManagedProcessSample]? = nil,
        usesApplicationCommands: Bool = true,
        launchedAt: Date? = nil,
        cpuPercent: Double = 50,
        isFrontmost: Bool = false,
        isHidden: Bool = true,
        isPlayingAudio: Bool = false,
        isProtectedByMenuBarOverlay: Bool = false,
        isProtectedAudioInfrastructure: Bool = false,
        windowVisibility: AppWindowVisibility = .hiddenOrMinimized
    ) -> ProcessControlTarget {
        ProcessControlTarget(
            bundleIdentifier: identifier ?? self.identifier,
            processIdentities: processIdentities,
            processSamples: processSamples,
            usesApplicationCommands: usesApplicationCommands,
            launchedAt: launchedAt,
            cpuPercent: cpuPercent,
            isFrontmost: isFrontmost,
            isHidden: isHidden,
            isPlayingAudio: isPlayingAudio,
            windowVisibility: windowVisibility,
            isProtectedByMenuBarOverlay: isProtectedByMenuBarOverlay,
            isProtectedAudioInfrastructure: isProtectedAudioInfrastructure
        )
    }

    @Test("A Spotify-shaped group stops only its expensive renderer")
    func multiProcessLimitStopsOnlyExpensiveRenderer() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let main = process(201)
        let renderer = process(202)
        let network = process(203)
        let storage = process(204)
        let samples = [
            ManagedProcessSample(identity: main, cpuPercent: 3, isMainProcess: true),
            ManagedProcessSample(identity: renderer, cpuPercent: 55, isMainProcess: false),
            ManagedProcessSample(
                identity: network,
                cpuPercent: 0.4,
                isMainProcess: false,
                networkActivity: .active
            ),
            ManagedProcessSample(identity: storage, cpuPercent: 0.2, isMainProcess: false),
        ]
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            frontmostProvider: { nil },
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [main, renderer, network, storage],
                processSamples: samples,
                launchedAt: oldLaunchDate,
                cpuPercent: 58.6
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 9)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        system.setCPUTimeNanoseconds(8_000_000)
        manualClock.advance(by: .milliseconds(10))
        #expect(await eventually { system.didAttemptToStop(renderer) })
        #expect(!system.didAttemptToStop(main))
        #expect(!system.didAttemptToStop(network))
        #expect(!system.didAttemptToStop(storage))
        #expect(await controller.currentSnapshot().statuses[identifier] == .limited(9))
        await controller.shutdown()
    }

    @Test("A connected single-process app waits without being stopped")
    func connectedSingleProcessWaits() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let onlineProcess = process(205)
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            frontmostProvider: { nil },
            clock: manualClock.clock
        )

        let snapshot = await controller.update(
            targets: [target(
                processIdentities: [onlineProcess],
                processSamples: [ManagedProcessSample(
                    identity: onlineProcess,
                    cpuPercent: 80,
                    isMainProcess: true,
                    networkActivity: .active
                )],
                launchedAt: oldLaunchDate,
                cpuPercent: 80
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 9)],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .networkProtected)
        manualClock.advance(by: .seconds(2))
        #expect(!system.didAttemptToStop(onlineProcess))
        await controller.shutdown()
    }

    @Test("Changing CPU contributors resumes the old subset before selecting the new one")
    func changingContributorsResumesOldSubset() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let main = process(206)
        let firstWorker = process(207)
        let secondWorker = process(208)
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            frontmostProvider: { nil },
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [main, firstWorker, secondWorker],
                processSamples: [
                    ManagedProcessSample(identity: main, cpuPercent: 1, isMainProcess: true),
                    ManagedProcessSample(
                        identity: firstWorker,
                        cpuPercent: 80,
                        isMainProcess: false
                    ),
                    ManagedProcessSample(
                        identity: secondWorker,
                        cpuPercent: 5,
                        isMainProcess: false
                    ),
                ],
                launchedAt: oldLaunchDate,
                cpuPercent: 86
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 10)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })
        system.setCPUTimeNanoseconds(8_000_000)
        manualClock.advance(by: .milliseconds(10))
        #expect(await eventually { system.didAttemptToStop(firstWorker) })

        _ = await controller.update(
            targets: [target(
                processIdentities: [main, firstWorker, secondWorker],
                processSamples: [
                    ManagedProcessSample(identity: main, cpuPercent: 1, isMainProcess: true),
                    ManagedProcessSample(
                        identity: firstWorker,
                        cpuPercent: 5,
                        isMainProcess: false
                    ),
                    ManagedProcessSample(
                        identity: secondWorker,
                        cpuPercent: 80,
                        isMainProcess: false
                    ),
                ],
                launchedAt: oldLaunchDate,
                cpuPercent: 86
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 10)],
            isEnabled: true,
            revision: 2
        )

        #expect(system.didAttemptToResume(firstWorker))
        #expect(!system.didAttemptToStop(secondWorker))
        await controller.shutdown()
    }

    @Test("A failed subset transition stops management instead of freezing a replacement")
    func failedSubsetTransitionStopsManagement() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let main = process(209)
        let firstWorker = process(210)
        let secondWorker = process(211)
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            frontmostProvider: { nil },
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [main, firstWorker, secondWorker],
                processSamples: [
                    ManagedProcessSample(identity: main, cpuPercent: 1, isMainProcess: true),
                    ManagedProcessSample(
                        identity: firstWorker,
                        cpuPercent: 80,
                        isMainProcess: false
                    ),
                    ManagedProcessSample(
                        identity: secondWorker,
                        cpuPercent: 5,
                        isMainProcess: false
                    ),
                ],
                launchedAt: oldLaunchDate,
                cpuPercent: 86
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 10)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })
        system.setCPUTimeNanoseconds(8_000_000)
        manualClock.advance(by: .milliseconds(10))
        #expect(await eventually { system.didAttemptToStop(firstWorker) })
        system.failResume(for: firstWorker, attempts: 3)

        let failed = await controller.update(
            targets: [target(
                processIdentities: [main, firstWorker, secondWorker],
                processSamples: [
                    ManagedProcessSample(identity: main, cpuPercent: 1, isMainProcess: true),
                    ManagedProcessSample(
                        identity: firstWorker,
                        cpuPercent: 5,
                        isMainProcess: false
                    ),
                    ManagedProcessSample(
                        identity: secondWorker,
                        cpuPercent: 80,
                        isMainProcess: false
                    ),
                ],
                launchedAt: oldLaunchDate,
                cpuPercent: 86
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 10)],
            isEnabled: true,
            revision: 2
        )

        #expect(failed.statuses[identifier] == .unavailable)
        #expect(!system.didAttemptToStop(secondWorker))
        system.failResume(for: firstWorker, attempts: 0)
        _ = await controller.shutdown()
    }

    @Test("Menu quit restores a paused app before requesting termination")
    func menuQuitRestoresPausedApp() async {
        let controlledProcess = process(100)
        let processSystem = RecordingProcessSystem()
        var terminatedIdentifier: String?
        let controller = ProcessController(
            system: processSystem,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            terminateApplication: { identifier in
                terminatedIdentifier = identifier
                return true
            }
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        let outcome = await controller.performApplicationCommand(
            .quit,
            bundleIdentifier: identifier
        )

        #expect(outcome == .succeeded)
        #expect(processSystem.didAttemptToResume(controlledProcess))
        #expect(terminatedIdentifier == identifier)
        #expect(await controller.currentSnapshot().statuses[identifier] == .waiting)
        await controller.shutdown()
    }

    @Test("SoundSource rules and direct commands cannot stop audio infrastructure")
    func soundSourceControlIsBlocked() async {
        let soundSourceIdentifier = "com.rogueamoeba.FutureSoundSourceHost"
        let controlledProcess = process(101)
        let processSystem = RecordingProcessSystem()
        var terminationCallCount = 0
        let controller = ProcessController(
            system: processSystem,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            terminateApplication: { _ in
                terminationCallCount += 1
                return true
            }
        )
        let rule = AppRule(
            bundleIdentifier: soundSourceIdentifier,
            displayName: "SoundSource",
            action: .pause,
            quitAfterMinutes: 1
        )

        _ = await controller.update(
            targets: [target(
                identifier: soundSourceIdentifier,
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                isProtectedAudioInfrastructure: true
            )],
            rules: [soundSourceIdentifier: rule],
            isEnabled: true,
            revision: 1
        )
        let outcome = await controller.performApplicationCommand(
            .quit,
            bundleIdentifier: soundSourceIdentifier
        )

        #expect(outcome == .failed(.compatibilityProtected))
        #expect(!processSystem.didAttemptToStop(controlledProcess))
        #expect(!processSystem.didAttemptToTerminate(controlledProcess))
        #expect(terminationCallCount == 0)
        await controller.shutdown()
    }

    @Test("A pending menu quit is not replaced by management when the app is frontmost")
    func pendingMenuQuitRemainsWaitingWhileFrontmost() async {
        var terminationCallCount = 0
        let controller = ProcessController(terminateApplication: { _ in
            terminationCallCount += 1
            return true
        })
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause
        )
        let frontmostTarget = target(
            launchedAt: oldLaunchDate,
            isFrontmost: true,
            isHidden: false,
            windowVisibility: .visible
        )

        _ = await controller.update(
            targets: [frontmostTarget],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        let outcome = await controller.performApplicationCommand(
            .quit,
            bundleIdentifier: identifier
        )
        let snapshot = await controller.update(
            targets: [frontmostTarget],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 2
        )

        #expect(outcome == .succeeded)
        #expect(terminationCallCount == 1)
        #expect(snapshot.statuses[identifier] == .waiting)
        await controller.shutdown()
    }

    @Test("Menu quit terminates a standalone process without an app command")
    func menuQuitTerminatesStandaloneProcess() async {
        let controlledProcess = process(150)
        let processSystem = RecordingProcessSystem()
        var applicationTerminationCallCount = 0
        let controller = ProcessController(
            system: processSystem,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            terminateApplication: { _ in
                applicationTerminationCallCount += 1
                return true
            }
        )
        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                usesApplicationCommands: false,
                launchedAt: oldLaunchDate
            )],
            rules: [:],
            isEnabled: true,
            revision: 1
        )

        let outcome = await controller.performApplicationCommand(
            .quit,
            bundleIdentifier: identifier
        )

        #expect(outcome == .succeeded)
        #expect(processSystem.didAttemptToTerminate(controlledProcess))
        #expect(applicationTerminationCallCount == 0)
        await controller.shutdown()
    }

    @Test("Menu quit stops when a paused app cannot be restored")
    func menuQuitStopsOnRestorationFailure() async {
        let controlledProcess = process(101)
        let processSystem = RecordingProcessSystem()
        var terminationCallCount = 0
        let controller = ProcessController(
            system: processSystem,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            terminateApplication: { _ in
                terminationCallCount += 1
                return true
            }
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        processSystem.failResume(for: controlledProcess, attempts: 3)
        let outcome = await controller.performApplicationCommand(
            .quit,
            bundleIdentifier: identifier
        )

        #expect(outcome == .failed(.restorationFailed))
        #expect(terminationCallCount == 0)
        #expect(await controller.currentSnapshot().statuses[identifier] == .unavailable)
        await controller.shutdown()
    }

    @Test("Rejected app commands report failure without inventing success")
    func rejectedAppCommand() async {
        let controller = ProcessController(activateApplication: { _ in false })
        _ = await controller.update(
            targets: [target()],
            rules: [:],
            isEnabled: true,
            revision: 1
        )

        let outcome = await controller.performApplicationCommand(
            .bringToFront,
            bundleIdentifier: identifier
        )

        #expect(outcome == .failed(.requestRejected))
        await controller.shutdown()
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

    @Test("A newer revision prevents a suspended pause from stopping the process")
    func newerRevisionPreventsSuspendedPause() async {
        let controlledProcess = process(103)
        let system = RecordingProcessSystem()
        let watchdog = SuspendedProcessCrashWatchdog()
        let controller = ProcessController(
            system: system,
            crashWatchdog: watchdog,
            frontmostProvider: { nil }
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause
        )
        let controlledTarget = target(
            processIdentities: [controlledProcess],
            launchedAt: oldLaunchDate
        )

        let staleUpdate = Task {
            await controller.update(
                targets: [controlledTarget],
                rules: [identifier: rule],
                isEnabled: true,
                revision: 1
            )
        }
        #expect(await eventuallyAsync { await watchdog.preparationStarted })

        let currentUpdate = Task {
            await controller.update(
                targets: [controlledTarget],
                rules: [:],
                isEnabled: true,
                revision: 2
            )
        }
        #expect(await eventuallyAsync {
            await controller.currentSnapshot().revision == 2
        })

        await watchdog.releasePreparation()
        _ = await staleUpdate.value
        let current = await currentUpdate.value

        #expect(current.revision == 2)
        #expect(current.statuses[identifier] == nil)
        #expect(!system.didAttemptToStop(controlledProcess))
        await controller.shutdown()
    }

    @Test("A newer revision restores a stop that completes after rule removal")
    func newerRevisionRestoresLateStop() async {
        let controlledProcess = process(104)
        let manualClock = ManualProcessControlClock()
        let system = SuspendedStopProcessSystem()
        let watchdog = RecordingProcessCrashWatchdog()
        let controller = ProcessController(
            system: system,
            crashWatchdog: watchdog,
            frontmostProvider: { nil },
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            limitPercent: 10
        )
        let controlledTarget = target(
            processIdentities: [controlledProcess],
            launchedAt: oldLaunchDate,
            cpuPercent: 100
        )

        _ = await controller.update(
            targets: [controlledTarget],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        manualClock.advance(by: .milliseconds(50))
        #expect(await eventuallyAsync { await system.stopStarted })

        let currentUpdate = Task {
            await controller.update(
                targets: [controlledTarget],
                rules: [:],
                isEnabled: true,
                revision: 2
            )
        }
        #expect(await eventuallyAsync {
            await controller.currentSnapshot().revision == 2
        })

        await system.releaseStop()
        let current = await currentUpdate.value

        #expect(current.revision == 2)
        #expect(current.statuses[identifier] == nil)
        #expect(await system.didResume(controlledProcess))
        #expect(!(await system.isStopped(controlledProcess)))
        #expect(!watchdog.isTracking(controlledProcess))
        await controller.shutdown()
    }

    @Test("Unmanaged apps do not resynchronize paused process state")
    func unmanagedAppsDoNotResynchronizePausedProcesses() async {
        let controlledProcess = process(101)
        let unmanagedProcess = process(102)
        let processSystem = RecordingProcessSystem()
        let watchdog = RecordingProcessCrashWatchdog()
        let controller = ProcessController(system: processSystem, crashWatchdog: watchdog)
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause
        )

        let snapshot = await controller.update(
            targets: [
                target(
                    processIdentities: [controlledProcess],
                    launchedAt: Date().addingTimeInterval(-61)
                ),
                target(
                    identifier: "unmanaged.app",
                    processIdentities: [unmanagedProcess],
                    launchedAt: Date().addingTimeInterval(-61)
                ),
            ],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .paused)
        #expect(snapshot.statuses["unmanaged.app"] == nil)
        #expect(watchdog.preparationCallCount == 1)
        #expect(watchdog.synchronizationCallCount == 1)
        #expect(!processSystem.didAttemptToResume(unmanagedProcess))
        await controller.shutdown()
    }

    @Test("Removing a pause rule restores its stopped process")
    func removingPauseRuleRestoresStoppedProcess() async {
        let controlledProcess = process(103)
        let processSystem = RecordingProcessSystem()
        let watchdog = RecordingProcessCrashWatchdog()
        let controller = ProcessController(system: processSystem, crashWatchdog: watchdog)
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: Date().addingTimeInterval(-61)
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        let restored = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: Date().addingTimeInterval(-61)
            )],
            rules: [:],
            isEnabled: true,
            revision: 2
        )

        #expect(processSystem.didAttemptToResume(controlledProcess))
        #expect(!watchdog.isTracking(controlledProcess))
        #expect(restored.statuses[identifier] == nil)
        #expect(restored.scheduledTickInterval == nil)
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

    @Test("An app at its CPU allowance stays at normal priority without hard limiting")
    func oldLaunchStaysAtNormalPriority() async {
        let system = RecordingProcessSystem()
        let controlledProcess = process(30)
        let controller = ProcessController(system: system)
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 0
        )
        let snapshot = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: Date().addingTimeInterval(-61)
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[identifier] == .normal)
        #expect(!system.didAttemptToSetBackgroundPriority(controlledProcess))
        #expect(!system.didAttemptToStop(controlledProcess))
        #expect(snapshot.scheduledTickInterval == 1)
        await controller.shutdown()
    }

    @Test("WindowServer limit rules use efficiency scheduling without hard limiting")
    func windowServerCannotBeCPULimited() async {
        let system = RecordingProcessSystem()
        let controlledProcess = process(31)
        let controller = ProcessController(system: system)
        let windowServerIdentifier = BackgroundProcessPolicy.identifier(
            command: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            pid: controlledProcess.pid
        )
        let rule = AppRule(
            bundleIdentifier: windowServerIdentifier,
            displayName: "WindowServer",
            action: .limit,
            limitPercent: 1,
            delaySeconds: 0
        )
        let snapshot = await controller.update(
            targets: [target(
                identifier: windowServerIdentifier,
                processIdentities: [controlledProcess],
                usesApplicationCommands: false,
                launchedAt: Date().addingTimeInterval(-61)
            )],
            rules: [windowServerIdentifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(snapshot.statuses[windowServerIdentifier] == .energyEfficient)
        #expect(system.didAttemptToSetBackgroundPriority(controlledProcess))
        #expect(!system.didAttemptToStop(controlledProcess))
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
        let controlledProcess = process(31)
        let controller = ProcessController(system: RecordingProcessSystem())
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 0
        )
        let launchedAt = Date().addingTimeInterval(-61)
        let background = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: launchedAt
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        let visible = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: launchedAt,
                windowVisibility: .visible
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 2
        )

        #expect(background.statuses[identifier] == .normal)
        #expect(visible.statuses[identifier] == .waiting)
        await controller.shutdown()
    }

    @Test("Visibility recheck releases active CPU control")
    func visibilityRecheckReleasesControl() async {
        let manualClock = ManualProcessControlClock()
        let controller = ProcessController(
            system: RecordingProcessSystem(),
            windowSnapshotProvider: { nil },
            clock: manualClock.clock
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 0
        )
        let controlledProcess = process(32)
        let background = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: Date().addingTimeInterval(-61)
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })
        manualClock.advance(by: .seconds(1))
        for _ in 0..<1_000 {
            if await controller.currentSnapshot().statuses[identifier] == .waiting {
                break
            }
            await Task.yield()
        }
        let protected = await controller.currentSnapshot()

        #expect(background.statuses[identifier] == .normal)
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
        let controller = ProcessController(system: RecordingProcessSystem())
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            delaySeconds: 0
        )
        let snapshot = await controller.update(
            targets: [target(
                processIdentities: [process(33)],
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
            crashWatchdog: RecordingProcessCrashWatchdog(),
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
            crashWatchdog: RecordingProcessCrashWatchdog(),
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
                    cpuPercent: 200
                )
            ],
            rules: rules,
            isEnabled: true,
            revision: 1
        )

        #expect(await eventually { manualClock.sleepRegistrationCount == 2 })
        manualClock.advance(by: .milliseconds(4))
        #expect(!system.didAttemptToStop(firstProcess))
        #expect(!system.didAttemptToStop(secondProcess))
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToStop(secondProcess) })
        #expect(!system.didAttemptToStop(firstProcess))
        #expect(await eventually { manualClock.sleepRegistrationCount == 3 })

        manualClock.advance(by: .milliseconds(4))
        #expect(!system.didAttemptToStop(firstProcess))
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToStop(firstProcess) })
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
            crashWatchdog: RecordingProcessCrashWatchdog(),
            controlInterval: 0.5,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 200
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
                cpuPercent: 200
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 20)],
            isEnabled: true,
            revision: 2
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        manualClock.advance(by: .milliseconds(5))
        #expect(!system.didAttemptToStop(controlledProcess))
        manualClock.advance(by: .milliseconds(5))
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
            crashWatchdog: RecordingProcessCrashWatchdog(),
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
            crashWatchdog: RecordingProcessCrashWatchdog(),
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
            crashWatchdog: RecordingProcessCrashWatchdog(),
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
            crashWatchdog: RecordingProcessCrashWatchdog(),
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

    @Test("Audio protection survives a brief playback gap before pausing")
    func audioProtectionSurvivesBriefPlaybackGap() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(70)
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            clock: manualClock.clock
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause,
            protectAudio: true
        )

        let protected = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                isPlayingAudio: true
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(protected.statuses[identifier] == .audioProtected)
        #expect(protected.scheduledTickInterval == nil)
        #expect(manualClock.pendingSleepCount == 0)
        #expect(!system.didAttemptToStop(controlledProcess))

        manualClock.advance(by: .seconds(14))
        let briefGap = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                isPlayingAudio: false
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 2
        )

        #expect(briefGap.statuses[identifier] == .audioProtected)
        #expect(briefGap.scheduledTickInterval == 15)
        #expect(!system.didAttemptToStop(controlledProcess))
        #expect(await eventually { manualClock.pendingSleepCount == 1 })

        manualClock.advance(by: .seconds(14))
        #expect(!system.didAttemptToStop(controlledProcess))
        #expect(await controller.currentSnapshot().statuses[identifier] == .audioProtected)

        manualClock.advance(by: .milliseconds(1_001))
        #expect(manualClock.deadlineWakeCount == 1)
        #expect(manualClock.pendingSleepCount == 0)
        #expect(await eventually { system.didAttemptToStop(controlledProcess) })
        #expect(await eventuallyAsync {
            await controller.currentSnapshot().statuses[identifier] == .paused
        })
        #expect(await eventuallyAsync {
            guard let interval = await controller.currentSnapshot().scheduledTickInterval else {
                return false
            }
            return interval > 0.9 && interval <= 1
        })
        let paused = await controller.currentSnapshot()

        #expect(paused.statuses[identifier] == .paused)
        #expect((paused.scheduledTickInterval ?? 0) > 0.9)
        #expect((paused.scheduledTickInterval ?? 2) <= 1)
        await controller.shutdown()
    }

    @Test("Frontmost audio protects the first background sample")
    func frontmostAudioProtectsFirstBackgroundSample() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(71)
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            frontmostProvider: { nil },
            clock: manualClock.clock
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause,
            protectAudio: true
        )

        let frontmost = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                isFrontmost: true,
                isPlayingAudio: true
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        #expect(frontmost.statuses[identifier] == .normal)

        let firstBackgroundSample = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                isPlayingAudio: false
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 2
        )

        #expect(firstBackgroundSample.statuses[identifier] == .audioProtected)
        #expect(firstBackgroundSample.scheduledTickInterval == 15)
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
            crashWatchdog: RecordingProcessCrashWatchdog(),
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

    @Test("An unavailable watchdog prevents Tempra from pausing a process")
    func unavailableWatchdogPreventsPause() async {
        let system = RecordingProcessSystem()
        let watchdog = RecordingProcessCrashWatchdog()
        watchdog.failPreparation()
        let controlledProcess = process(13)
        let controller = ProcessController(
            system: system,
            crashWatchdog: watchdog
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause
        )

        let snapshot = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )

        #expect(!system.didAttemptToStop(controlledProcess))
        #expect(snapshot.statuses[identifier] == .unavailable)
        #expect(!watchdog.isTracking(controlledProcess))
        _ = await controller.shutdown()
    }

    @Test("Shutdown reports unresolved processes and succeeds after a retry")
    func shutdownReportsRestorationFailure() async throws {
        let system = RecordingProcessSystem()
        let watchdog = RecordingProcessCrashWatchdog()
        let controlledProcess = process(14)
        let controller = ProcessController(
            system: system,
            crashWatchdog: watchdog
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        #expect(system.didAttemptToStop(controlledProcess))
        #expect(watchdog.isTracking(controlledProcess))

        system.failResume(for: controlledProcess, attempts: 3)
        let failed = await controller.shutdown()
        let failure = try #require(failed.failures.first)
        #expect(!failed.succeeded)
        #expect(failure.bundleIdentifier == identifier)
        #expect(failure.stoppedProcesses == [controlledProcess])
        #expect(watchdog.disarmCallCount == 0)
        #expect(watchdog.isTracking(controlledProcess))

        let succeeded = await controller.shutdown()
        #expect(succeeded.succeeded)
        #expect(watchdog.disarmCallCount == 1)
        #expect(!watchdog.isTracking(controlledProcess))
    }

    @Test("Shutdown reports priority restoration failures")
    func shutdownReportsPriorityFailure() async throws {
        let system = RecordingProcessSystem()
        let watchdog = RecordingProcessCrashWatchdog()
        let controlledProcess = process(15)
        let controller = ProcessController(
            system: system,
            crashWatchdog: watchdog
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            runOnEfficiencyCores: true
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate
            )],
            rules: [identifier: rule],
            isEnabled: true,
            revision: 1
        )
        system.failPriorityRestore(for: controlledProcess, attempts: 3)

        let failed = await controller.shutdown()
        let failure = try #require(failed.failures.first)
        #expect(!failed.succeeded)
        #expect(failure.stoppedProcesses.isEmpty)
        #expect(failure.backgroundPriorityProcesses == [controlledProcess])

        let succeeded = await controller.shutdown()
        #expect(succeeded.succeeded)
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
            crashWatchdog: RecordingProcessCrashWatchdog(),
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

    @Test("Application activation immediately restores a CPU-limited process")
    func applicationActivationRestoresLimitedProcess() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let watchdog = RecordingProcessCrashWatchdog()
        let controlledProcess = process(36)
        let controller = ProcessController(
            system: system,
            crashWatchdog: watchdog,
            frontmostProvider: { nil },
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 800
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 1)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        system.setCPUTimeNanoseconds(8_000_000)
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToStop(controlledProcess) })
        #expect(watchdog.isTracking(controlledProcess))

        let activated = await controller.applicationDidActivate(
            bundleIdentifier: identifier
        )

        #expect(system.didAttemptToResume(controlledProcess))
        #expect(activated.statuses[identifier] == .normal)
        #expect(!watchdog.isTracking(controlledProcess))
        let stopCountAfterActivation = system.stopAttemptCount
        manualClock.advance(by: .milliseconds(350))
        #expect(system.stopAttemptCount == stopCountAfterActivation)
        await controller.shutdown()
    }

    @Test("Activation invalidates a CPU-limit stop that is already in flight")
    func applicationActivationInvalidatesInFlightStop() async {
        let manualClock = ManualProcessControlClock()
        let system = SuspendedStopProcessSystem()
        let watchdog = RecordingProcessCrashWatchdog()
        let controlledProcess = process(37)
        let controller = ProcessController(
            system: system,
            crashWatchdog: watchdog,
            frontmostProvider: { nil },
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
        #expect(await eventually { manualClock.pendingSleepCount == 2 })
        manualClock.advance(by: .milliseconds(10))
        #expect(await eventuallyAsync { await system.stopStarted })

        let activated = await controller.applicationDidActivate(
            bundleIdentifier: identifier
        )
        #expect(activated.statuses[identifier] == .normal)

        await system.releaseStop()
        #expect(await eventuallyAsync { await system.didResume(controlledProcess) })
        #expect(!(await system.isStopped(controlledProcess)))
        #expect(!watchdog.isTracking(controlledProcess))
        await controller.shutdown()
    }

    @Test("Minimum run duration remains enforced")
    func minimumRunDurationIsEnforced() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(11)
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
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

    @Test("The default limiter bounds a busy-process pulse to ten milliseconds")
    func defaultLimiterBoundsBurstDuration() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(16)
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
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
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        system.setCPUTimeNanoseconds(10_000_000)
        manualClock.advance(by: .milliseconds(9))
        #expect(!system.didAttemptToStop(controlledProcess))
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToStop(controlledProcess) })
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        manualClock.advance(by: .milliseconds(89))
        #expect(!system.didAttemptToResume(controlledProcess))
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToResume(controlledProcess) })
        await controller.shutdown()
    }

    @Test("Adaptive pulses preserve a fifty-percent CPU allowance")
    func adaptivePulsesPreserveHigherAllowance() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(38)
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 100
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 50)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        system.setCPUTimeNanoseconds(50_000_000)
        manualClock.advance(by: .milliseconds(49))
        #expect(!system.didAttemptToStop(controlledProcess))
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToStop(controlledProcess) })
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        manualClock.advance(by: .milliseconds(49))
        #expect(!system.didAttemptToResume(controlledProcess))
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToResume(controlledProcess) })
        await controller.shutdown()
    }

    @Test("A measured CPU burst cannot starve app responsiveness")
    func measuredCPUBurstHasBoundedRecovery() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(17)
        let hiddenSnapshot = WindowVisibilitySnapshot(windowsFrontToBack: [], screenBounds: [])
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            windowSnapshotProvider: { hiddenSnapshot },
            controlInterval: 0.1,
            minimumRunDuration: 0.005,
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 50
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 50)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        system.setCPUTimeNanoseconds(800_000_000)
        manualClock.advance(by: .milliseconds(999))
        #expect(!system.didAttemptToStop(controlledProcess))
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToStop(controlledProcess) })
        var stopped = await controller.currentSnapshot()
        for _ in 0..<1_000 {
            if stopped.statuses[identifier] == .limited(50) { break }
            await Task.yield()
            stopped = await controller.currentSnapshot()
        }
        #expect(stopped.statuses[identifier] == .limited(50))

        #expect(await eventually { manualClock.pendingSleepCount == 2 })
        manualClock.advance(by: .milliseconds(105))
        for _ in 0..<1_000 {
            if system.didAttemptToResume(controlledProcess) { break }
            _ = await controller.currentSnapshot()
            await Task.yield()
        }
        #expect(!system.didAttemptToResume(controlledProcess))
        manualClock.advance(by: .milliseconds(2))
        #expect(await eventually { system.didAttemptToResume(controlledProcess) })
        await controller.shutdown()
    }

    @Test("A low CPU limit receives a responsiveness slice within 350 milliseconds")
    func lowLimitReceivesResponsivenessSlice() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(18)
        let hiddenSnapshot = WindowVisibilitySnapshot(windowsFrontToBack: [], screenBounds: [])
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            windowSnapshotProvider: { hiddenSnapshot },
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 800
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 1)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        system.setCPUTimeNanoseconds(8_000_000)
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToStop(controlledProcess) })
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        manualClock.advance(by: .milliseconds(349))
        #expect(!system.didAttemptToResume(controlledProcess))
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToResume(controlledProcess) })
        await controller.shutdown()
    }

    @Test("A seven-percent limit adapts an eight-core burst to one-millisecond pulses")
    func sevenPercentLimitUsesAdaptiveMicroPulses() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let watchdog = RecordingProcessCrashWatchdog()
        let controlledProcess = process(35)
        let hiddenSnapshot = WindowVisibilitySnapshot(windowsFrontToBack: [], screenBounds: [])
        let controller = ProcessController(
            system: system,
            crashWatchdog: watchdog,
            windowSnapshotProvider: { hiddenSnapshot },
            clock: manualClock.clock
        )

        _ = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 800
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 7)],
            isEnabled: true,
            revision: 1
        )
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        system.setCPUTimeNanoseconds(8_000_000)
        manualClock.advance(by: .milliseconds(1))
        #expect(await eventually { system.didAttemptToStop(controlledProcess) })
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        manualClock.advance(by: .milliseconds(113))
        #expect(!system.didAttemptToResume(controlledProcess))
        manualClock.advance(by: .microseconds(286))
        #expect(await eventually { system.didAttemptToResume(controlledProcess) })
        #expect(watchdog.isTracking(controlledProcess))

        let elapsedSeconds = 0.114286
        let averagedCPUPercent = Double(8_000_000)
            / (elapsedSeconds * 1_000_000_000)
            * 100
        #expect(averagedCPUPercent <= 8)
        await controller.shutdown()
    }

    @Test("Measured CPU must exceed the allowance before hard limiting starts")
    func measuredDemandGatesHardLimiting() async {
        let manualClock = ManualProcessControlClock()
        let system = RecordingProcessSystem()
        let controlledProcess = process(34)
        let hiddenSnapshot = WindowVisibilitySnapshot(windowsFrontToBack: [], screenBounds: [])
        let controller = ProcessController(
            system: system,
            crashWatchdog: RecordingProcessCrashWatchdog(),
            windowSnapshotProvider: { hiddenSnapshot },
            clock: manualClock.clock
        )

        let initial = await controller.update(
            targets: [target(
                processIdentities: [controlledProcess],
                launchedAt: oldLaunchDate,
                cpuPercent: 10
            )],
            rules: [identifier: limitRule(identifier, limitPercent: 20)],
            isEnabled: true,
            revision: 1
        )

        #expect(initial.statuses[identifier] == .normal)
        #expect(!system.didAttemptToSetBackgroundPriority(controlledProcess))
        #expect(!system.didAttemptToStop(controlledProcess))
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        system.setCPUTimeNanoseconds(100_000_000)
        manualClock.advance(by: .seconds(1))
        #expect(await eventually { manualClock.deadlineWakeCount >= 1 })
        #expect(await controller.currentSnapshot().statuses[identifier] == .normal)
        #expect(!system.didAttemptToStop(controlledProcess))
        #expect(await eventually { manualClock.pendingSleepCount == 2 })

        system.setCPUTimeNanoseconds(400_000_000)
        manualClock.advance(by: .seconds(1))
        #expect(await eventually { system.didAttemptToStop(controlledProcess) })
        #expect(await eventuallyAsync {
            await controller.currentSnapshot().statuses[identifier] == .limited(20)
        })
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
            crashWatchdog: RecordingProcessCrashWatchdog(),
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

        manualClock.advance(by: .milliseconds(950))
        #expect(await eventually { manualClock.pendingSleepCount == 2 })
        system.setCPUTimeNanoseconds(10_000_000)
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return condition()
            }
        }
        return condition()
    }

    private func eventuallyAsync(
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return await condition()
            }
        }
        return await condition()
    }
}

private enum RecordingWatchdogError: Error {
    case unavailable
}

private actor SuspendedProcessCrashWatchdog: ProcessCrashWatchdogControlling {
    private(set) var preparationStarted = false
    private var preparationContinuation: CheckedContinuation<Void, Never>?

    func prepareToStop(_ processes: Set<ProcessIdentity>) async throws {
        preparationStarted = true
        await withCheckedContinuation { continuation in
            preparationContinuation = continuation
        }
    }

    func synchronize(_ processes: Set<ProcessIdentity>) {}
    func disarm() {}

    func releasePreparation() {
        preparationContinuation?.resume()
        preparationContinuation = nil
    }
}

private actor SuspendedStopProcessSystem: ProcessSystemControlling {
    private(set) var stopStarted = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stoppedProcesses: Set<ProcessIdentity> = []
    private var resumedProcesses: Set<ProcessIdentity> = []

    func totalCPUTime(for processes: Set<ProcessIdentity>) -> UInt64 {
        0
    }

    func stop(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        stopStarted = true
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
        stoppedProcesses.formUnion(processes)
        return ProcessOperationResult(applied: processes)
    }

    func resume(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        stoppedProcesses.subtract(processes)
        resumedProcesses.formUnion(processes)
        return ProcessOperationResult(applied: processes)
    }

    func setBackgroundPriority(
        _ processes: Set<ProcessIdentity>
    ) -> ProcessOperationResult {
        ProcessOperationResult(applied: processes)
    }

    func restorePriority(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        ProcessOperationResult(applied: processes)
    }

    func terminate(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        ProcessOperationResult(applied: processes)
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func didResume(_ process: ProcessIdentity) -> Bool {
        resumedProcesses.contains(process)
    }

    func isStopped(_ process: ProcessIdentity) -> Bool {
        stoppedProcesses.contains(process)
    }
}

private final class RecordingProcessCrashWatchdog: ProcessCrashWatchdogControlling,
    @unchecked Sendable {
    private let lock = NSLock()
    private var trackedProcesses: Set<ProcessIdentity> = []
    private var shouldFailPreparation = false
    private var preparationCalls = 0
    private var synchronizationCalls = 0
    private var disarmCalls = 0

    var preparationCallCount: Int {
        withLock { preparationCalls }
    }

    var synchronizationCallCount: Int {
        withLock { synchronizationCalls }
    }

    var disarmCallCount: Int {
        withLock { disarmCalls }
    }

    func isTracking(_ process: ProcessIdentity) -> Bool {
        withLock { trackedProcesses.contains(process) }
    }

    func failPreparation() {
        withLock {
            shouldFailPreparation = true
        }
    }

    func prepareToStop(_ processes: Set<ProcessIdentity>) async throws {
        try withLock {
            preparationCalls += 1
            guard !shouldFailPreparation else {
                throw RecordingWatchdogError.unavailable
            }
            trackedProcesses.formUnion(processes)
        }
    }

    func synchronize(_ processes: Set<ProcessIdentity>) async throws {
        withLock {
            synchronizationCalls += 1
            trackedProcesses = processes
        }
    }

    func disarm() async {
        withLock {
            trackedProcesses.removeAll()
            disarmCalls += 1
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class RecordingProcessSystem: ProcessSystemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var stopAttempts: [Set<ProcessIdentity>] = []
    private var resumeAttempts: [Set<ProcessIdentity>] = []
    private var backgroundPriorityAttempts: [Set<ProcessIdentity>] = []
    private var terminationAttempts: [Set<ProcessIdentity>] = []
    private var cpuTimeNanoseconds: UInt64 = 0
    private var stopFailuresRemaining: [ProcessIdentity: Int] = [:]
    private var resumeFailuresRemaining: [ProcessIdentity: Int] = [:]
    private var priorityRestoreFailuresRemaining: [ProcessIdentity: Int] = [:]

    var stopAttemptCount: Int {
        withLock { stopAttempts.count }
    }

    func didAttemptToStop(_ process: ProcessIdentity) -> Bool {
        withLock { stopAttempts.contains { $0.contains(process) } }
    }

    func didAttemptToResume(_ process: ProcessIdentity) -> Bool {
        withLock { resumeAttempts.contains { $0.contains(process) } }
    }

    func didAttemptToSetBackgroundPriority(_ process: ProcessIdentity) -> Bool {
        withLock { backgroundPriorityAttempts.contains { $0.contains(process) } }
    }

    func didAttemptToTerminate(_ process: ProcessIdentity) -> Bool {
        withLock { terminationAttempts.contains { $0.contains(process) } }
    }

    func failNextStop(for process: ProcessIdentity) {
        withLock {
            stopFailuresRemaining[process, default: 0] += 1
        }
    }

    func failResume(for process: ProcessIdentity, attempts: Int) {
        withLock {
            resumeFailuresRemaining[process] = max(0, attempts)
        }
    }

    func failPriorityRestore(for process: ProcessIdentity, attempts: Int) {
        withLock {
            priorityRestoreFailuresRemaining[process] = max(0, attempts)
        }
    }

    func setCPUTimeNanoseconds(_ value: UInt64) {
        withLock {
            cpuTimeNanoseconds = value
        }
    }

    func totalCPUTime(for processes: Set<ProcessIdentity>) -> UInt64 {
        withLock { cpuTimeNanoseconds }
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
            var result = ProcessOperationResult()
            for process in processes {
                let failures = resumeFailuresRemaining[process, default: 0]
                if failures > 0 {
                    resumeFailuresRemaining[process] = failures - 1
                    result.failed.insert(process)
                } else {
                    result.applied.insert(process)
                }
            }
            return result
        }
    }

    func setBackgroundPriority(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        withLock {
            backgroundPriorityAttempts.append(processes)
            return ProcessOperationResult(applied: processes)
        }
    }

    func restorePriority(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        withLock {
            var result = ProcessOperationResult()
            for process in processes {
                let failures = priorityRestoreFailuresRemaining[process, default: 0]
                if failures > 0 {
                    priorityRestoreFailuresRemaining[process] = failures - 1
                    result.failed.insert(process)
                } else {
                    result.applied.insert(process)
                }
            }
            return result
        }
    }

    func terminate(_ processes: Set<ProcessIdentity>) -> ProcessOperationResult {
        withLock {
            terminationAttempts.append(processes)
            return ProcessOperationResult(applied: processes)
        }
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
