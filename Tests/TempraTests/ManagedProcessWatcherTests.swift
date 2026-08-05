import CoreAudio
import Darwin
import Foundation
import Testing
@testable import Tempra

@Suite("Managed process event ordering")
@MainActor
struct ManagedProcessWatcherTests {
    @Test("Managed process events are coalesced for a quarter second by default")
    func defaultDebounceCoalescesProcessEvents() async {
        let audioMonitor = RecordingAudioActivityMonitor()
        let watcher = ManagedProcessWatcher(audioMonitor: audioMonitor)
        var notifications: [ProcessChangeNotification] = []
        watcher.watch(
            processIdentities: [],
            audioProcessIdentifiers: [],
            onChange: { notifications.append($0) }
        )
        let identity = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000_000)
        let notification = ManagedProcessWatcher.notification(
            for: .fork,
            identity: identity
        )

        watcher.handleProcessChange(for: notification)
        try? await Task.sleep(for: .milliseconds(50))
        watcher.handleProcessChange(for: notification)

        #expect(notifications.isEmpty)
        #expect(await eventually(timeout: .seconds(1)) { notifications.count == 1 })

        await watcher.stop()
    }

    @Test("Rapid managed process events use only the short debounce")
    func rapidProcessEventsUseShortDebounce() async {
        let audioMonitor = RecordingAudioActivityMonitor()
        let watcher = ManagedProcessWatcher(
            audioMonitor: audioMonitor,
            eventDebounceInterval: 0.01
        )
        var notifications: [ProcessChangeNotification] = []
        watcher.watch(
            processIdentities: [],
            audioProcessIdentifiers: [],
            onChange: { notifications.append($0) }
        )
        let identity = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000_000)
        let notification = ManagedProcessWatcher.notification(
            for: .exec,
            identity: identity
        )

        watcher.handleProcessChange(for: notification)
        #expect(await eventually { notifications.count == 1 })
        watcher.handleProcessChange(for: notification)
        #expect(await eventually { notifications.count == 2 })

        await watcher.stop()
    }

    @Test("Audio watch updates apply the newest revision before shutdown")
    func audioWatchUpdatesAreOrdered() async {
        let audioMonitor = RecordingAudioActivityMonitor()
        let watcher = ManagedProcessWatcher(audioMonitor: audioMonitor)

        watcher.watch(
            processIdentities: [],
            audioProcessIdentifiers: [1],
            onChange: { _ in }
        )
        watcher.watch(
            processIdentities: [],
            audioProcessIdentifiers: [2],
            onChange: { _ in }
        )
        watcher.watch(
            processIdentities: [],
            audioProcessIdentifiers: [3],
            onChange: { _ in }
        )

        #expect(await eventually {
            await audioMonitor.events == [.watch(revision: 3, processIdentifiers: [3])]
        })
        await watcher.stop()

        #expect(await audioMonitor.events == [
            .watch(revision: 3, processIdentifiers: [3]),
            .stop(revision: 4)
        ])
    }

    @Test("An unchanged audio target set does not rebuild Core Audio listeners")
    func unchangedAudioTargetsAreNotReconfigured() async {
        let audioMonitor = RecordingAudioActivityMonitor()
        let watcher = ManagedProcessWatcher(audioMonitor: audioMonitor)

        watcher.watch(
            processIdentities: [],
            audioProcessIdentifiers: [1],
            onChange: { _ in }
        )
        #expect(await eventually {
            await audioMonitor.events == [.watch(revision: 1, processIdentifiers: [1])]
        })

        watcher.watch(
            processIdentities: [],
            audioProcessIdentifiers: [1],
            onChange: { _ in }
        )
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await audioMonitor.events == [
            .watch(revision: 1, processIdentifiers: [1])
        ])

        await watcher.stop()
    }

    @Test("Shutdown waits for an in-flight audio update before stopping")
    func shutdownOrdersAudioStopAfterInFlightUpdate() async {
        let audioMonitor = SuspendedAudioActivityMonitor()
        let watcher = ManagedProcessWatcher(audioMonitor: audioMonitor)
        var stopStarted = false
        var stopCompleted = false

        watcher.watch(
            processIdentities: [],
            audioProcessIdentifiers: [7],
            onChange: { _ in }
        )
        #expect(await eventually { await audioMonitor.watchStarted })

        let stopTask = Task { @MainActor in
            stopStarted = true
            await watcher.stop()
            stopCompleted = true
        }
        #expect(await eventually { stopStarted })
        #expect(!stopCompleted)

        await audioMonitor.releaseWatch()
        await stopTask.value

        #expect(stopCompleted)
        #expect(await audioMonitor.events == [
            .watch(revision: 1, processIdentifiers: [7]),
            .stop(revision: 2)
        ])
    }

    @Test("Older audio configurations cannot replace newer configurations")
    func staleAudioConfigurationIsIgnored() async {
        let backend = RecordingAudioBackend(processObjects: [10: 110, 20: 120])
        let monitor = AudioActivityMonitor(backend: backend)

        await monitor.watch(
            revision: 2,
            processIdentifiers: [20],
            onActivityChange: {}
        )
        await monitor.watch(
            revision: 1,
            processIdentifiers: [10],
            onActivityChange: {}
        )
        #expect(backend.runningOutputTargets == [120])

        await monitor.stop(revision: 3)
        await monitor.watch(
            revision: 2,
            processIdentifiers: [10],
            onActivityChange: {}
        )
        #expect(backend.listenerTargets.isEmpty)
    }

    @Test("Callbacks from replaced audio listeners are ignored")
    func staleAudioCallbackIsIgnored() async throws {
        let backend = RecordingAudioBackend(processObjects: [10: 110, 20: 120])
        let monitor = AudioActivityMonitor(backend: backend)
        var activityCount = 0

        await monitor.watch(
            revision: 1,
            processIdentifiers: [10],
            onActivityChange: { activityCount += 1 }
        )
        let staleCallback = try #require(backend.callback(for: .runningOutput(110)))
        await monitor.watch(
            revision: 2,
            processIdentifiers: [20],
            onActivityChange: { activityCount += 1 }
        )

        staleCallback()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(activityCount == 0)

        let currentCallback = try #require(backend.callback(for: .runningOutput(120)))
        currentCallback()
        #expect(await eventually { activityCount == 1 })

        await monitor.stop(revision: 3)
    }

    @Test("Retained audio listeners use the current watch revision")
    func retainedAudioListenerRemainsActive() async throws {
        let backend = RecordingAudioBackend(processObjects: [10: 110, 20: 120])
        let monitor = AudioActivityMonitor(backend: backend)
        var activityCount = 0

        await monitor.watch(
            revision: 1,
            processIdentifiers: [10],
            onActivityChange: { activityCount += 1 }
        )
        let retainedCallback = try #require(backend.callback(for: .runningOutput(110)))

        await monitor.watch(
            revision: 2,
            processIdentifiers: [10, 20],
            onActivityChange: { activityCount += 1 }
        )
        retainedCallback()

        #expect(await eventually { activityCount == 1 })
        await monitor.stop(revision: 3)
    }

    private func eventually(
        timeout: Duration = .milliseconds(500),
        _ condition: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private actor RecordingAudioActivityMonitor: AudioActivityMonitoring {
    enum Event: Equatable, Sendable {
        case watch(revision: UInt64, processIdentifiers: Set<pid_t>)
        case stop(revision: UInt64)
    }

    private(set) var events: [Event] = []

    func watch(
        revision: UInt64,
        processIdentifiers: Set<pid_t>,
        onActivityChange: @escaping ActivityHandler
    ) {
        events.append(.watch(
            revision: revision,
            processIdentifiers: processIdentifiers
        ))
    }

    func stop(revision: UInt64) {
        events.append(.stop(revision: revision))
    }
}

private actor SuspendedAudioActivityMonitor: AudioActivityMonitoring {
    private(set) var events: [RecordingAudioActivityMonitor.Event] = []
    private(set) var watchStarted = false
    private var watchContinuation: CheckedContinuation<Void, Never>?

    func watch(
        revision: UInt64,
        processIdentifiers: Set<pid_t>,
        onActivityChange: @escaping ActivityHandler
    ) async {
        events.append(.watch(
            revision: revision,
            processIdentifiers: processIdentifiers
        ))
        watchStarted = true
        await withCheckedContinuation { continuation in
            watchContinuation = continuation
        }
    }

    func stop(revision: UInt64) {
        events.append(.stop(revision: revision))
    }

    func releaseWatch() {
        watchContinuation?.resume()
        watchContinuation = nil
    }
}

private final class RecordingAudioBackend: AudioActivityBackend, @unchecked Sendable {
    private struct Registration {
        let target: AudioListenerTarget
        let callback: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let processObjects: [pid_t: AudioObjectID]
    private var registrations: [AudioListenerToken: Registration] = [:]

    init(processObjects: [pid_t: AudioObjectID]) {
        self.processObjects = processObjects
    }

    var listenerTargets: Set<AudioListenerTarget> {
        withLock { Set(registrations.values.map(\.target)) }
    }

    var runningOutputTargets: Set<AudioObjectID> {
        Set(listenerTargets.compactMap { target in
            guard case .runningOutput(let objectID) = target else { return nil }
            return objectID
        })
    }

    func processObject(for processIdentifier: pid_t) -> AudioObjectID? {
        processObjects[processIdentifier]
    }

    func addListener(
        for target: AudioListenerTarget,
        onChange: @escaping @Sendable () -> Void
    ) -> AudioListenerToken? {
        withLock {
            let token = AudioListenerToken()
            registrations[token] = Registration(target: target, callback: onChange)
            return token
        }
    }

    func removeListener(_ token: AudioListenerToken) {
        _ = withLock {
            registrations.removeValue(forKey: token)
        }
    }

    func callback(for target: AudioListenerTarget) -> (@Sendable () -> Void)? {
        withLock {
            registrations.values.first { $0.target == target }?.callback
        }
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
