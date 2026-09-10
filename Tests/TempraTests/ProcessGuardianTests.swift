import Darwin
import Foundation
import Testing
@testable import Tempra
@testable import TempraWatchdog
import TempraSafety

@Suite("Process guardian")
struct ProcessGuardianTests {
    @Test("A reconnect records guarded processes as restored")
    func reconnectRecordsGuardedProcessesAsRestored() {
        let process = clientProcessIdentity(pid: 2_001)
        let guardianInstanceID = UUID()
        var state = ProcessGuardianProtectionState()

        state.connected(to: guardianInstanceID)
        state.prepared([process], stale: [])
        state.connectionLost()
        state.connected(to: guardianInstanceID)

        #expect(state.protectedProcesses.isEmpty)
        #expect(state.restoredProcesses == [process])
        #expect(state.requiresSynchronization(with: []))
    }

    @Test("A new preparation protects a process again after recovery")
    func preparationProtectsProcessAgainAfterRecovery() {
        let process = clientProcessIdentity(pid: 2_002)
        let guardianInstanceID = UUID()
        var state = ProcessGuardianProtectionState()

        state.connected(to: guardianInstanceID)
        state.prepared([process], stale: [])
        state.connectionLost()
        state.connected(to: guardianInstanceID)
        state.prepared([process], stale: [])

        #expect(state.protectedProcesses == [process])
        #expect(state.restoredProcesses.isEmpty)
    }

    @Test("A new guardian instance records guarded processes as restored")
    func newGuardianInstanceRecordsGuardedProcessesAsRestored() {
        let process = clientProcessIdentity(pid: 2_003)
        var state = ProcessGuardianProtectionState()

        state.connected(to: UUID())
        state.prepared([process], stale: [])
        state.connected(to: UUID())

        #expect(state.guardianInstanceID != nil)
        #expect(state.protectedProcesses.isEmpty)
        #expect(state.restoredProcesses == [process])
    }

    @Test("Preparation sends only processes that do not have protection")
    func preparationSelectsOnlyUnprotectedProcesses() {
        let protected = clientProcessIdentity(pid: 2_006)
        let unprotected = clientProcessIdentity(pid: 2_007)
        var state = ProcessGuardianProtectionState()
        state.connected(to: UUID())
        state.prepared([protected], stale: [])

        let selected = state.processesRequiringPreparation(
            from: [protected, unprotected]
        )

        #expect(selected == [unprotected])
    }

    @Test("Unchanged guardian state does not require synchronization")
    func unchangedGuardianStateSkipsSynchronization() {
        let process = clientProcessIdentity(pid: 2_008)
        var state = ProcessGuardianProtectionState()
        state.connected(to: UUID())
        state.prepared([process], stale: [])

        #expect(!state.requiresSynchronization(with: [process]))
        #expect(state.requiresSynchronization(with: []))

        state.connectionLost()
        #expect(state.requiresSynchronization(with: [process]))
        #expect(state.processesRequiringPreparation(from: [process]) == [process])
    }

    @Test("Unchanged automatic resume state does not require synchronization")
    func unchangedAutomaticResumeStateSkipsSynchronization() {
        let process = clientProcessIdentity(pid: 2_009)
        let intervals = [process: 0.099]

        #expect(!ProcessGuardianClient.requiresAutomaticResumeSynchronization(
            requested: intervals,
            cached: intervals,
            connectionIsCurrent: true
        ))
        #expect(ProcessGuardianClient.requiresAutomaticResumeSynchronization(
            requested: intervals,
            cached: [:],
            connectionIsCurrent: true
        ))
        #expect(ProcessGuardianClient.requiresAutomaticResumeSynchronization(
            requested: intervals,
            cached: intervals,
            connectionIsCurrent: false
        ))
    }

    @Test("Connection loss restores a stopped process")
    func connectionLossRestoresStoppedProcess() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }

        let sessionID = UUID()
        let controller = ProcessGuardianStateController(journalStore: store)
        let stopResponse = await send(
            try request(
                sessionID: sessionID,
                revision: 1,
                action: .stop,
                processes: [sleeper.identity]
            ),
            to: controller
        )

        #expect(stopResponse.errorCode == nil)
        #expect(stopResponse.applied == [sleeper.identity])
        #expect(await eventuallyStatus(of: sleeper.process.processIdentifier, isStopped: true))
        #expect(try store.load().trackedProcesses == [sleeper.identity])

        await invalidate(sessionID: sessionID, in: controller)

        #expect(await eventuallyStatus(of: sleeper.process.processIdentifier, isStopped: false))
        let recoveredState = try store.load()
        #expect(recoveredState.trackedProcesses.isEmpty)
        #expect(recoveredState.sessionID == nil)
    }

    @Test("An expired lease restores a stopped process")
    func expiredLeaseRestoresStoppedProcess() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let clock = LockedGuardianClock(now: 1_000_000_000)
        let controller = ProcessGuardianStateController(
            journalStore: store,
            clock: { clock.read() }
        )
        let sessionID = UUID()

        let stopResponse = await send(
            try request(
                sessionID: sessionID,
                revision: 1,
                action: .stop,
                processes: [sleeper.identity]
            ),
            to: controller
        )
        #expect(stopResponse.errorCode == nil)
        #expect(await eventuallyStatus(of: sleeper.process.processIdentifier, isStopped: true))

        clock.advance(
            by: (ProcessGuardianProtocol.leaseDurationMilliseconds + 1) * 1_000_000
        )
        let leaseResponse = await send(
            try request(
                sessionID: sessionID,
                revision: 2,
                action: .ping
            ),
            to: controller
        )

        #expect(leaseResponse.errorCode == .leaseExpired)
        #expect(await eventuallyStatus(of: sleeper.process.processIdentifier, isStopped: false))
        #expect(try store.load().trackedProcesses.isEmpty)
    }

    @Test("The lease timer restores a stopped process without another request")
    func leaseTimerRestoresStoppedProcessWithoutRequest() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let controller = ProcessGuardianStateController(
            journalStore: store,
            leaseDurationNanoseconds: 50_000_000
        )
        controller.start()

        let stopResponse = await send(
            try request(
                sessionID: UUID(),
                revision: 1,
                action: .stop,
                processes: [sleeper.identity]
            ),
            to: controller
        )

        #expect(stopResponse.errorCode == nil)
        #expect(await eventuallyStatus(
            of: sleeper.process.processIdentifier,
            isStopped: false
        ))
        #expect(try store.load().trackedProcesses.isEmpty)
    }

    @Test("Connection loss restores a backgrounded process the app journaled")
    func connectionLossRestoresBackgroundedProcess() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let sessionID = UUID()
        let controller = ProcessGuardianStateController(journalStore: store)
        let pid = sleeper.process.processIdentifier

        // The app journals first, then backgrounds locally: the same order
        // RoutedProcessSystemController uses.
        let prepared = await send(
            try request(
                sessionID: sessionID,
                revision: 1,
                action: .prepareBackground,
                processes: [sleeper.identity]
            ),
            to: controller
        )
        #expect(prepared.errorCode == nil)
        #expect(prepared.applied == [sleeper.identity])
        #expect(try store.load().backgroundedProcesses.map(\.process) == [sleeper.identity])
        #expect(try store.load().trackedProcesses.isEmpty)
        #expect(!isBackgrounded(pid))

        try ProcessPriorityController().lowerPriority(from: .normal, for: pid)
        #expect(isBackgrounded(pid))

        await invalidate(sessionID: sessionID, in: controller)

        #expect(await eventually { !self.isBackgrounded(pid) })
        let recovered = try store.load()
        #expect(recovered.backgroundedProcesses.isEmpty)
        #expect(recovered.sessionID == nil)
    }

    @Test("Background synchronization restores processes dropped from the set")
    func backgroundSynchronizationRestoresDroppedProcesses() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let sessionID = UUID()
        let controller = ProcessGuardianStateController(journalStore: store)
        let pid = sleeper.process.processIdentifier

        _ = await send(
            try request(
                sessionID: sessionID,
                revision: 1,
                action: .prepareBackground,
                processes: [sleeper.identity]
            ),
            to: controller
        )
        try ProcessPriorityController().lowerPriority(from: .normal, for: pid)
        #expect(isBackgrounded(pid))

        let response = await send(
            try request(
                sessionID: sessionID,
                revision: 2,
                action: .synchronizeBackground
            ),
            to: controller
        )

        #expect(response.errorCode == nil)
        #expect(response.applied == [sleeper.identity])
        #expect(!isBackgrounded(pid))
        #expect(try store.load().backgroundedProcesses.isEmpty)
    }

    @Test("Disarm releases stopped processes but keeps backgrounded ones guarded")
    func disarmKeepsBackgroundedProcessesGuarded() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let paused = try startSleeper()
        defer { stopSleeper(paused.process) }
        let sessionID = UUID()
        let controller = ProcessGuardianStateController(journalStore: store)
        let pid = sleeper.process.processIdentifier

        _ = await send(
            try request(
                sessionID: sessionID,
                revision: 1,
                action: .prepareBackground,
                processes: [sleeper.identity]
            ),
            to: controller
        )
        try ProcessPriorityController().lowerPriority(from: .normal, for: pid)
        _ = await send(
            try request(
                sessionID: sessionID,
                revision: 2,
                action: .stop,
                processes: [paused.identity]
            ),
            to: controller
        )
        #expect(await eventuallyStatus(of: paused.process.processIdentifier, isStopped: true))

        let response = await send(
            try request(sessionID: sessionID, revision: 3, action: .disarm),
            to: controller
        )

        #expect(response.errorCode == nil)
        #expect(await eventuallyStatus(of: paused.process.processIdentifier, isStopped: false))
        #expect(isBackgrounded(pid))
        let state = try store.load()
        #expect(state.trackedProcesses.isEmpty)
        #expect(state.backgroundedProcesses.map(\.process) == [sleeper.identity])
        #expect(state.sessionID == sessionID)
    }

    @Test("A guardian restart restores journaled backgrounded processes")
    func guardianRestartRestoresBackgroundedProcesses() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let pid = sleeper.process.processIdentifier
        var firstController: ProcessGuardianStateController? =
            ProcessGuardianStateController(journalStore: store)
        _ = await send(
            try request(
                sessionID: UUID(),
                revision: 1,
                action: .prepareBackground,
                processes: [sleeper.identity]
            ),
            to: try #require(firstController)
        )
        try ProcessPriorityController().lowerPriority(from: .normal, for: pid)
        #expect(isBackgrounded(pid))
        firstController = nil

        _ = ProcessGuardianStateController(journalStore: store)

        #expect(await eventually { !self.isBackgrounded(pid) })
        #expect(try store.load().backgroundedProcesses.isEmpty)
    }

    @Test("A guardian restart restores journaled processes")
    func guardianRestartRestoresJournaledProcesses() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let sessionID = UUID()
        var firstController: ProcessGuardianStateController? =
            ProcessGuardianStateController(journalStore: store)
        let stopResponse = await send(
            try request(
                sessionID: sessionID,
                revision: 1,
                action: .stop,
                processes: [sleeper.identity]
            ),
            to: try #require(firstController)
        )
        #expect(stopResponse.errorCode == nil)
        #expect(await eventuallyStatus(of: sleeper.process.processIdentifier, isStopped: true))
        firstController = nil

        _ = ProcessGuardianStateController(journalStore: store)

        #expect(await eventuallyStatus(of: sleeper.process.processIdentifier, isStopped: false))
        let recoveredState = try store.load()
        #expect(recoveredState.trackedProcesses.isEmpty)
        #expect(recoveredState.sessionID == nil)
    }

    @Test("Synchronization reports a removed guarded process")
    func synchronizationReportsRemovedGuardedProcess() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let sessionID = UUID()
        let controller = ProcessGuardianStateController(journalStore: store)

        _ = await send(
            try request(
                sessionID: sessionID,
                revision: 1,
                action: .stop,
                processes: [sleeper.identity]
            ),
            to: controller
        )
        #expect(await eventuallyStatus(
            of: sleeper.process.processIdentifier,
            isStopped: true
        ))

        let response = await send(
            try request(
                sessionID: sessionID,
                revision: 2,
                action: .synchronize
            ),
            to: controller
        )

        #expect(response.errorCode == nil)
        #expect(response.applied == [sleeper.identity])
        #expect(await eventuallyStatus(
            of: sleeper.process.processIdentifier,
            isStopped: false
        ))
        #expect(try store.load().trackedProcesses.isEmpty)
    }

    @Test("Disarm reports a journal write failure")
    func disarmReportsJournalWriteFailure() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let sessionID = UUID()
        let controller = ProcessGuardianStateController(journalStore: store)

        _ = await send(
            try request(
                sessionID: sessionID,
                revision: 1,
                action: .stop,
                processes: [sleeper.identity]
            ),
            to: controller
        )
        #expect(await eventuallyStatus(
            of: sleeper.process.processIdentifier,
            isStopped: true
        ))

        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(
            at: store.fileURL,
            withIntermediateDirectories: false
        )
        let response = await send(
            try request(
                sessionID: sessionID,
                revision: 2,
                action: .disarm
            ),
            to: controller
        )

        #expect(response.errorCode == .recoveryFailed)
        #expect(response.errorMessage != nil)
        #expect(await eventuallyStatus(
            of: sleeper.process.processIdentifier,
            isStopped: false
        ))

        try FileManager.default.removeItem(at: store.fileURL)
        await invalidate(sessionID: sessionID, in: controller)
        #expect(try store.load().trackedProcesses.isEmpty)
    }

    @Test("A reused process identifier does not receive a signal")
    func reusedProcessIdentifierDoesNotReceiveSignal() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let staleIdentity = WatchdogProcessIdentity(
            pid: sleeper.identity.pid,
            startTimeMicroseconds: sleeper.identity.startTimeMicroseconds + 1
        )
        let state = ProcessGuardianJournalState(
            sessionID: UUID(),
            revision: 1,
            owner: try ownerIdentity(),
            trackedProcesses: [staleIdentity]
        )
        try store.save(state)

        _ = ProcessGuardianStateController(journalStore: store)

        #expect(await eventuallyStatus(of: sleeper.process.processIdentifier, isStopped: false))
        #expect(sleeper.process.isRunning)
        #expect(try store.load().trackedProcesses.isEmpty)
    }

    @Test("A rejected batch does not report an unstopped process as stopped")
    func rejectedBatchDoesNotReportUnstoppedProcessAsStopped() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let owner = try ownerIdentity()
        let controller = ProcessGuardianStateController(journalStore: store)

        let response = await send(
            ProcessGuardianRequest(
                sessionID: UUID(),
                revision: 1,
                action: .stop,
                owner: owner,
                processes: [sleeper.identity, owner]
            ),
            to: controller
        )

        #expect(response.errorCode == nil)
        #expect(response.applied.isEmpty)
        #expect(Set(response.failed) == [sleeper.identity, owner])
        #expect(await eventuallyStatus(
            of: sleeper.process.processIdentifier,
            isStopped: false
        ))
        #expect(try store.load().trackedProcesses.isEmpty)
    }

    @Test("The journal rejects invalid saved state")
    func journalRejectsInvalidSavedState() throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: store.fileURL)

        #expect(throws: ProcessGuardianJournalError.self) {
            try store.load()
        }
        #expect(throws: ProcessGuardianClientError.self) {
            try ProcessGuardianJournalProbe(fileURL: store.fileURL).isClear()
        }
    }

    @Test("Registration waits for a guarded journal to clear")
    func registrationWaitsForGuardedJournalToClear() throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let probe = ProcessGuardianJournalProbe(fileURL: store.fileURL)
        let guardedProcess = WatchdogProcessIdentity(
            pid: 2_004,
            startTimeMicroseconds: 2_004_000
        )

        #expect(try probe.isClear())
        try store.save(ProcessGuardianJournalState(
            sessionID: UUID(),
            revision: 1,
            owner: try ownerIdentity(),
            trackedProcesses: [guardedProcess]
        ))
        #expect(try !probe.isClear())

        try store.save(ProcessGuardianJournalState())
        #expect(try probe.isClear())
    }

    @Test("The protocol rejects ambiguous process state")
    func protocolRejectsAmbiguousProcessState() {
        let owner = WatchdogProcessIdentity(
            pid: 100,
            startTimeMicroseconds: 1_000
        )
        let process = WatchdogProcessIdentity(
            pid: 200,
            startTimeMicroseconds: 2_000
        )
        let valid = ProcessGuardianRequest(
            sessionID: UUID(),
            revision: 1,
            action: .stop,
            owner: owner,
            processes: [process],
            resumeDeadlines: [WatchdogResumeDeadline(
                process: process,
                resumeAfterMilliseconds: 500
            )]
        )
        #expect(valid.isValid)

        let duplicateProcessIdentifier = ProcessGuardianRequest(
            sessionID: UUID(),
            revision: 1,
            action: .prepare,
            owner: owner,
            processes: [
                process,
                WatchdogProcessIdentity(
                    pid: process.pid,
                    startTimeMicroseconds: process.startTimeMicroseconds + 1
                ),
            ]
        )
        #expect(!duplicateProcessIdentifier.isValid)

        let untrackedDeadline = ProcessGuardianRequest(
            sessionID: UUID(),
            revision: 1,
            action: .stop,
            owner: owner,
            processes: [],
            resumeDeadlines: [WatchdogResumeDeadline(
                process: process,
                resumeAfterMilliseconds: 500
            )]
        )
        #expect(!untrackedDeadline.isValid)

        let stateInPing = ProcessGuardianRequest(
            sessionID: UUID(),
            revision: 1,
            action: .ping,
            owner: owner,
            processes: [process]
        )
        #expect(!stateInPing.isValid)
    }

    @Test("The guardian derives the run slice from the 100ms pulse period")
    func guardianDerivesRunSliceFromPulsePeriod() {
        #expect(ProcessGuardianStateController.runIntervalNanoseconds(
            stopIntervalNanoseconds: 100_000_000
        ) == 1_000_000)
        #expect(ProcessGuardianStateController.runIntervalNanoseconds(
            stopIntervalNanoseconds: 50_000_000
        ) == 50_000_000)
    }

    @Test("Synchronization cancels the recurring automatic-resume pulse")
    func synchronizationCancelsAutomaticResumePulse() async throws {
        let (store, directoryURL) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sleeper = try startSleeper()
        defer { stopSleeper(sleeper.process) }
        let sessionID = UUID()
        let controller = ProcessGuardianStateController(journalStore: store)

        let stopResponse = await send(
            ProcessGuardianRequest(
                sessionID: sessionID,
                revision: 1,
                action: .stop,
                owner: try ownerIdentity(),
                processes: [sleeper.identity],
                resumeDeadlines: [WatchdogResumeDeadline(
                    process: sleeper.identity,
                    resumeAfterMilliseconds: 100
                )]
            ),
            to: controller
        )
        #expect(stopResponse.errorCode == nil)
        #expect(await eventuallyStatus(
            of: sleeper.process.processIdentifier,
            isStopped: true
        ))

        try await Task.sleep(for: .milliseconds(140))
        #expect(await eventuallyStatus(
            of: sleeper.process.processIdentifier,
            isStopped: true
        ))

        let synchronizeResponse = await send(
            try request(
                sessionID: sessionID,
                revision: 2,
                action: .synchronize
            ),
            to: controller
        )
        #expect(synchronizeResponse.errorCode == nil)
        #expect(await eventuallyStatus(
            of: sleeper.process.processIdentifier,
            isStopped: false
        ))
        try await Task.sleep(for: .milliseconds(140))
        #expect(!isStopped(sleeper.process.processIdentifier))
    }

    private func send(
        _ request: ProcessGuardianRequest,
        to controller: ProcessGuardianStateController
    ) async -> ProcessGuardianResponse {
        await withCheckedContinuation { continuation in
            controller.handle(
                request,
                connectionPID: getpid(),
                invalidateConnection: {},
                reply: { response in
                    continuation.resume(returning: response)
                }
            )
        }
    }

    private func invalidate(
        sessionID: UUID,
        in controller: ProcessGuardianStateController
    ) async {
        await withCheckedContinuation { continuation in
            controller.connectionInvalidated(sessionID: sessionID) {
                continuation.resume()
            }
        }
    }

    private func request(
        sessionID: UUID,
        revision: UInt64,
        action: ProcessGuardianAction,
        processes: [WatchdogProcessIdentity] = []
    ) throws -> ProcessGuardianRequest {
        ProcessGuardianRequest(
            sessionID: sessionID,
            revision: revision,
            action: action,
            owner: try ownerIdentity(),
            processes: processes
        )
    }

    private func ownerIdentity() throws -> WatchdogProcessIdentity {
        let identity = try #require(
            LiveProcessSystemController.currentIdentity(for: getpid())
        )
        return WatchdogProcessIdentity(
            pid: identity.pid,
            startTimeMicroseconds: identity.startTimeMicroseconds
        )
    }

    private func clientProcessIdentity(pid: pid_t) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            startTimeMicroseconds: UInt64(pid) * 1_000
        )
    }

    private func startSleeper() throws
        -> (process: Process, identity: WatchdogProcessIdentity) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let identity = try #require(
            LiveProcessSystemController.currentIdentity(
                for: process.processIdentifier
            )
        )
        return (
            process,
            WatchdogProcessIdentity(
                pid: identity.pid,
                startTimeMicroseconds: identity.startTimeMicroseconds
            )
        )
    }

    private func stopSleeper(_ process: Process) {
        _ = kill(process.processIdentifier, SIGCONT)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func eventuallyStatus(
        of pid: pid_t,
        isStopped expectedStopped: Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if isStopped(pid) == expectedStopped { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isStopped(pid) == expectedStopped
    }

    private func isStopped(_ pid: pid_t) -> Bool {
        guard let info = LiveProcessSystemController.bsdInfo(for: pid) else {
            return false
        }
        return UInt32(info.pbi_status) == UInt32(SSTOP)
    }

    private func isBackgrounded(_ pid: pid_t) -> Bool {
        (try? ProcessPriorityController().state(for: pid).isBackgrounded) ?? false
    }

    private func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func temporaryStore() throws
        -> (ProcessGuardianJournalStore, URL) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TempraProcessGuardianTests.\(UUID().uuidString)",
                isDirectory: true
            )
        return (
            ProcessGuardianJournalStore(
                fileURL: directoryURL.appendingPathComponent("state.json")
            ),
            directoryURL
        )
    }
}

private final class LockedGuardianClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64

    init(now: UInt64) {
        self.now = now
    }

    func read() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        let addition = now.addingReportingOverflow(nanoseconds)
        now = addition.overflow ? .max : addition.partialValue
        lock.unlock()
    }
}
