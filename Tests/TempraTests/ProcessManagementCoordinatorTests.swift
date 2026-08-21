import Darwin
import Foundation
import Testing

@testable import Tempra

@Suite("Process management coordination")
@MainActor
struct ProcessManagementCoordinatorTests {
    @Test("Shutdown waits for a late stop before restoring it")
    func shutdownWaitsForLateStopBeforeRestoringIt() async {
        let identity = ProcessIdentity(
            pid: getpid(),
            startTimeMicroseconds: 1_000_000
        )
        let identifier = "example.coordinator"
        let system = SuspendedCoordinatorProcessSystem()
        let controller = ProcessController(
            system: system,
            crashWatchdog: NoopCoordinatorCrashWatchdog(),
            frontmostProvider: { nil }
        )
        let coordinator = ProcessManagementCoordinator(
            controller: controller,
            processWatcher: ManagedProcessWatcher(eventDebounceInterval: 0)
        )
        let app = ManagedApp(
            bundleIdentifier: identifier,
            name: "Example",
            bundleURL: nil,
            processIdentifiers: [identity.pid],
            processIdentities: [identity],
            processSamples: [
                ManagedProcessSample(
                    identity: identity,
                    cpuPercent: 50,
                    isMainProcess: true
                )
            ],
            launchedAt: Date(timeIntervalSinceNow: -120),
            cpuPercent: 50,
            isFrontmost: false,
            isHidden: true,
            isPlayingAudio: false,
            isSystemProcess: false,
            status: .normal
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause
        )

        coordinator.update(
            apps: [app],
            rules: [identifier: rule],
            suspensions: [:],
            activeProfile: nil,
            isEnabled: true,
            onProcessChange: { _ in }
        )
        #expect(await eventually { await system.stopStarted })

        let completion = CoordinatorShutdownCompletion()
        let shutdownTask = Task { @MainActor in
            let result = await coordinator.shutdown()
            await completion.markCompleted()
            return result
        }

        try? await Task.sleep(for: .milliseconds(25))
        #expect(!(await completion.isCompleted))
        #expect(!(await system.didResume(identity)))

        await system.releaseStop()
        let result = await shutdownTask.value

        #expect(result.succeeded)
        #expect(await completion.isCompleted)
        #expect(await system.didResume(identity))
        #expect(!(await system.isStopped(identity)))
    }

    private func eventually(
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
}

private actor CoordinatorShutdownCompletion {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private actor NoopCoordinatorCrashWatchdog: ProcessCrashWatchdogControlling {
    func prepareToStop(_ processes: Set<ProcessIdentity>) async throws {}

    func armAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws {}

    func synchronizeAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws {}

    func synchronize(_ processes: Set<ProcessIdentity>) async throws {}

    func disarm() async {}
}

private actor SuspendedCoordinatorProcessSystem: ProcessSystemControlling {
    private(set) var stopStarted = false
    private var releaseRequested = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var stoppedProcesses: Set<ProcessIdentity> = []
    private var resumedProcesses: Set<ProcessIdentity> = []

    func totalCPUTime(for processes: Set<ProcessIdentity>) async throws -> UInt64 {
        0
    }

    func audioActivity(
        for processes: Set<ProcessIdentity>
    ) async -> ProcessAudioActivity {
        .inactive
    }

    func networkActivity(for process: ProcessIdentity) async -> ProcessNetworkActivity {
        .inactive
    }

    func criticalFileActivity(
        for process: ProcessIdentity
    ) async -> ProcessCriticalFileActivity {
        .inactive
    }

    func stop(
        _ processes: Set<ProcessIdentity>,
        automaticResumeAfter: TimeInterval?
    ) async -> ProcessOperationResult {
        stopStarted = true
        if !releaseRequested {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
        stoppedProcesses.formUnion(processes)
        return ProcessOperationResult(applied: processes)
    }

    func resume(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        stoppedProcesses.subtract(processes)
        resumedProcesses.formUnion(processes)
        return ProcessOperationResult(applied: processes)
    }

    func lowerPriority(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        ProcessOperationResult(applied: processes)
    }

    func restorePriority(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        ProcessOperationResult(applied: processes)
    }

    func applyLimitPriority(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        ProcessOperationResult(applied: processes)
    }

    func terminate(_ processes: Set<ProcessIdentity>) async -> ProcessOperationResult {
        ProcessOperationResult(applied: processes)
    }

    func releaseStop() {
        releaseRequested = true
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
