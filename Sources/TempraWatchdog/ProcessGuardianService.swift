import Darwin
import Foundation
import OSLog
import TempraSafety

private struct GuardianOperationResult {
    var applied: Set<WatchdogProcessIdentity> = []
    var stale: Set<WatchdogProcessIdentity> = []
    var failed: Set<WatchdogProcessIdentity> = []
}

private enum GuardianPulsePhase {
    case stopped
    case running
}

private struct GuardianAutomaticResumeState {
    let deadlineNanoseconds: UInt64
    let intervalNanoseconds: UInt64
    let phase: GuardianPulsePhase
}

final class ProcessGuardianStateController: @unchecked Sendable {
    typealias Clock = @Sendable () -> UInt64

    private static let recoveryAttempts = 3
    private static let recoveryRetryMicroseconds: useconds_t = 100_000
    private static let retryDelayNanoseconds: UInt64 = 1_000_000_000
    private static let pulsePeriodNanoseconds: UInt64 = 100_000_000
    private static let minimumRunNanoseconds: UInt64 = 1_000_000

    private let queue = DispatchQueue(
        label: "io.github.temperapp.Temper.process-guardian-state",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let journalStore: ProcessGuardianJournalStore
    private let clock: Clock
    private let leaseDurationNanoseconds: UInt64
    private let guardianInstanceID = UUID()
    private let logger = Logger(
        subsystem: ProcessGuardianProtocol.applicationIdentifier,
        category: "ProcessGuardian"
    )

    private var journalState: ProcessGuardianJournalState
    private var activeSessionID: UUID?
    private var activeOwner: WatchdogProcessIdentity?
    private var lastRevision: UInt64
    private var automaticResumeStates:
        [WatchdogProcessIdentity: GuardianAutomaticResumeState] = [:]
    private var leaseDeadlineNanoseconds: UInt64?
    private var recoveryRetryDeadlineNanoseconds: UInt64?
    private var timer: DispatchSourceTimer?
    private var blockingError: String?
    private var resetSessionAfterRecovery = false
    private var invalidateConnection: (@Sendable () -> Void)?

    init(
        journalStore: ProcessGuardianJournalStore,
        clock: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
        leaseDurationNanoseconds: UInt64 =
            ProcessGuardianProtocol.leaseDurationMilliseconds * 1_000_000
    ) {
        self.journalStore = journalStore
        self.clock = clock
        self.leaseDurationNanoseconds = leaseDurationNanoseconds

        do {
            let loaded = try journalStore.load()
            journalState = loaded
            activeSessionID = loaded.trackedProcesses.isEmpty
                ? nil
                : loaded.sessionID
            activeOwner = loaded.trackedProcesses.isEmpty ? nil : loaded.owner
            lastRevision = loaded.trackedProcesses.isEmpty ? 0 : loaded.revision
            resetSessionAfterRecovery = !loaded.trackedProcesses.isEmpty
        } catch {
            journalState = ProcessGuardianJournalState()
            activeSessionID = nil
            activeOwner = nil
            lastRevision = 0
            blockingError = error.localizedDescription
            return
        }

        guard !journalState.trackedProcesses.isEmpty else { return }
        let result = Self.resumeWithRetries(
            Set(journalState.trackedProcesses),
            attempts: Self.recoveryAttempts,
            retryMicroseconds: Self.recoveryRetryMicroseconds
        )
        let unresolved = result.failed
        do {
            if unresolved.isEmpty {
                try journalStore.save(ProcessGuardianJournalState())
                journalState = ProcessGuardianJournalState()
                activeSessionID = nil
                activeOwner = nil
                lastRevision = 0
                resetSessionAfterRecovery = false
            } else {
                journalState.trackedProcesses = Self.sorted(unresolved)
                journalState.automaticResumeIntervals = journalState
                    .automaticResumeIntervals.filter {
                        unresolved.contains($0.process)
                    }
                try journalStore.save(journalState)
                blockingError = "The process guardian could not restore every saved process."
                recoveryRetryDeadlineNanoseconds = Self.addingWithoutOverflow(
                    clock(),
                    Self.retryDelayNanoseconds
                )
            }
        } catch {
            blockingError = error.localizedDescription
            recoveryRetryDeadlineNanoseconds = Self.addingWithoutOverflow(
                clock(),
                Self.retryDelayNanoseconds
            )
        }
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }

    func start() {
        queue.async { [self] in
            scheduleTimer()
        }
    }

    func handle(
        _ request: ProcessGuardianRequest,
        connectionPID: pid_t,
        invalidateConnection: @escaping @Sendable () -> Void,
        reply: @escaping @Sendable (ProcessGuardianResponse) -> Void
    ) {
        queue.async { [self] in
            self.invalidateConnection = invalidateConnection
            reply(process(request, connectionPID: connectionPID))
        }
    }

    func connectionInvalidated(
        sessionID: UUID,
        completion: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            defer { completion() }
            guard activeSessionID == sessionID else { return }
            _ = recoverAll(resetSession: true)
        }
    }

    private func process(
        _ request: ProcessGuardianRequest,
        connectionPID: pid_t
    ) -> ProcessGuardianResponse {
        let now = clock()
        if let leaseDeadlineNanoseconds,
           !journalState.trackedProcesses.isEmpty,
           leaseDeadlineNanoseconds <= now {
            _ = recoverAll(resetSession: true)
            invalidateConnection?()
            return failure(
                request,
                code: .leaseExpired,
                message: "The process guardian lease expired. Managed processes were restored."
            )
        }

        if blockingError != nil {
            attemptPendingRecovery(now: now)
        }
        if let blockingError {
            scheduleTimer()
            return failure(
                request,
                code: .recoveryFailed,
                message: blockingError
            )
        }

        guard request.isValid,
              Int32(connectionPID) == request.owner.pid,
              Self.currentIdentity(for: connectionPID) == request.owner else {
            return failure(
                request,
                code: .invalidRequest,
                message: "The process guardian request identity is invalid."
            )
        }

        if let activeSessionID {
            guard activeSessionID == request.sessionID,
                  activeOwner == request.owner else {
                return failure(
                    request,
                    code: .sessionMismatch,
                    message: "The process guardian already has another active session."
                )
            }
        } else {
            activeSessionID = request.sessionID
            activeOwner = request.owner
        }

        guard request.revision > lastRevision else {
            return failure(
                request,
                code: .staleRevision,
                message: "The process guardian request revision is stale."
            )
        }
        lastRevision = request.revision
        refreshLease(now: now)

        let response: ProcessGuardianResponse
        switch request.action {
        case .ping, .renewLease:
            response = success(request)
        case .prepare:
            response = prepare(request)
        case .synchronize:
            response = synchronize(request)
        case .armResume:
            response = updateAutomaticResume(request, replacesAll: false)
        case .synchronizeResume:
            response = updateAutomaticResume(request, replacesAll: true)
        case .stop:
            response = stop(request)
        case .resume:
            response = resume(request)
        case .disarm:
            response = disarm(request)
        }
        scheduleTimer()
        return response
    }

    private func prepare(
        _ request: ProcessGuardianRequest
    ) -> ProcessGuardianResponse {
        guard let owner = activeOwner else {
            return failure(
                request,
                code: .sessionMismatch,
                message: "The process guardian session owner is unavailable."
            )
        }
        let requested = Set(request.processes)
        let classified = classifyForStop(requested, owner: owner)
        guard classified.failed.isEmpty else {
            return resultResponse(
                request,
                result: rejectedStopResult(classified)
            )
        }

        let tracked = Set(journalState.trackedProcesses)
            .union(classified.applied)
        do {
            try persist(
                tracked: tracked,
                automaticResumeIntervals: currentAutomaticResumeIntervals(),
                request: request
            )
            return resultResponse(request, result: classified)
        } catch {
            return failure(
                request,
                code: .journalFailure,
                message: error.localizedDescription,
                failed: classified.applied.union(classified.failed)
            )
        }
    }

    private func synchronize(
        _ request: ProcessGuardianRequest
    ) -> ProcessGuardianResponse {
        guard let owner = activeOwner else {
            return failure(
                request,
                code: .sessionMismatch,
                message: "The process guardian session owner is unavailable."
            )
        }
        let desiredClassification = classifyForTracking(
            Set(request.processes),
            owner: owner
        )
        let desired = desiredClassification.applied
        let tracked = Set(journalState.trackedProcesses)
        let removed = tracked.subtracting(desired)
        let restoration = Self.applySignal(SIGCONT, to: removed)
        let retained = desired.union(restoration.failed)
        let intervals = currentAutomaticResumeIntervals().filter {
            retained.contains($0.key)
        }
        do {
            try persist(
                tracked: retained,
                automaticResumeIntervals: intervals,
                request: request
            )
            synchronizeAutomaticResumeDeadlines(
                intervals: intervals,
                resetProcesses: [],
                replacesAll: true
            )
        } catch {
            return failure(
                request,
                code: .journalFailure,
                message: error.localizedDescription,
                failed: retained
            )
        }

        var result = desiredClassification
        result.applied.formUnion(restoration.applied)
        result.stale.formUnion(restoration.stale)
        result.failed.formUnion(restoration.failed)
        return resultResponse(request, result: result)
    }

    private func updateAutomaticResume(
        _ request: ProcessGuardianRequest,
        replacesAll: Bool
    ) -> ProcessGuardianResponse {
        let tracked = Set(journalState.trackedProcesses)
        let requestedProcesses = Set(request.resumeDeadlines.map(\.process))
        guard requestedProcesses.isSubset(of: tracked) else {
            return failure(
                request,
                code: .invalidRequest,
                message: "An automatic-resume process is not protected by the guardian."
            )
        }

        var intervals = replacesAll ? [:] : currentAutomaticResumeIntervals()
        for entry in request.resumeDeadlines {
            intervals[entry.process] = entry.resumeAfterMilliseconds
        }
        do {
            try persist(
                tracked: tracked,
                automaticResumeIntervals: intervals,
                request: request
            )
            synchronizeAutomaticResumeDeadlines(
                intervals: intervals,
                resetProcesses: replacesAll ? [] : requestedProcesses,
                replacesAll: replacesAll
            )
            return success(request)
        } catch {
            return failure(
                request,
                code: .journalFailure,
                message: error.localizedDescription
            )
        }
    }

    private func stop(_ request: ProcessGuardianRequest) -> ProcessGuardianResponse {
        guard let owner = activeOwner else {
            return failure(
                request,
                code: .sessionMismatch,
                message: "The process guardian session owner is unavailable."
            )
        }
        let requested = Set(request.processes)
        let classified = classifyForStop(requested, owner: owner)
        guard classified.failed.isEmpty else {
            return resultResponse(
                request,
                result: rejectedStopResult(classified)
            )
        }

        let priorTracked = Set(journalState.trackedProcesses)
        let proposedTracked = priorTracked.union(classified.applied)
        var proposedIntervals = currentAutomaticResumeIntervals()
        for entry in request.resumeDeadlines {
            proposedIntervals[entry.process] = entry.resumeAfterMilliseconds
        }
        do {
            try persist(
                tracked: proposedTracked,
                automaticResumeIntervals: proposedIntervals,
                request: request
            )
        } catch {
            return failure(
                request,
                code: .journalFailure,
                message: error.localizedDescription,
                failed: classified.applied.union(classified.failed)
            )
        }

        let signalResult = Self.applySignal(SIGSTOP, to: classified.applied)
        let stopped = signalResult.applied
        let retained = priorTracked.union(stopped)
        let retainedIntervals = proposedIntervals.filter {
            retained.contains($0.key)
        }
        do {
            try persist(
                tracked: retained,
                automaticResumeIntervals: retainedIntervals,
                request: request
            )
            synchronizeAutomaticResumeDeadlines(
                intervals: retainedIntervals,
                resetProcesses: stopped,
                replacesAll: true
            )
        } catch {
            let recovery = recoverAll(resetSession: false)
            return failure(
                request,
                code: recovery.failed.isEmpty ? .journalFailure : .recoveryFailed,
                message: recovery.failed.isEmpty
                    ? error.localizedDescription
                    : "The guardian journal failed and a managed process could not be restored.",
                failed: requested
            )
        }

        var result = signalResult
        result.stale.formUnion(classified.stale)
        result.failed.formUnion(classified.failed)
        return resultResponse(request, result: result)
    }

    private func resume(_ request: ProcessGuardianRequest) -> ProcessGuardianResponse {
        let requested = Set(request.processes)
        let tracked = Set(journalState.trackedProcesses)
        let unowned = requested.subtracting(tracked)
        guard unowned.isEmpty else {
            return failure(
                request,
                code: .invalidRequest,
                message: "The guardian can resume only processes that it protects.",
                failed: unowned
            )
        }

        let result = Self.applySignal(SIGCONT, to: requested)
        let resolved = result.applied.union(result.stale)
        let retained = tracked.subtracting(resolved)
        let intervals = currentAutomaticResumeIntervals().filter {
            retained.contains($0.key)
        }
        do {
            try persist(
                tracked: retained,
                automaticResumeIntervals: intervals,
                request: request
            )
            automaticResumeStates = automaticResumeStates.filter {
                retained.contains($0.key)
            }
            return resultResponse(request, result: result)
        } catch {
            blockingError = error.localizedDescription
            recoveryRetryDeadlineNanoseconds = Self.addingWithoutOverflow(
                clock(),
                Self.retryDelayNanoseconds
            )
            return failure(
                request,
                code: .journalFailure,
                message: error.localizedDescription,
                failed: result.failed
            )
        }
    }

    private func disarm(_ request: ProcessGuardianRequest) -> ProcessGuardianResponse {
        let result = recoverAll(resetSession: false)
        guard result.failed.isEmpty, blockingError == nil else {
            return failure(
                request,
                code: .recoveryFailed,
                message: blockingError
                    ?? "The process guardian could not restore every managed process.",
                failed: result.failed
            )
        }
        return resultResponse(request, result: result)
    }

    @discardableResult
    private func recoverAll(resetSession: Bool) -> GuardianOperationResult {
        if resetSession {
            resetSessionAfterRecovery = true
        }
        let tracked = Set(journalState.trackedProcesses)
        let result = Self.resumeWithRetries(
            tracked,
            attempts: Self.recoveryAttempts,
            retryMicroseconds: Self.recoveryRetryMicroseconds
        )
        let unresolved = result.failed
        let intervals = currentAutomaticResumeIntervals().filter {
            unresolved.contains($0.key)
        }

        do {
            if resetSessionAfterRecovery, unresolved.isEmpty {
                try journalStore.save(ProcessGuardianJournalState())
                journalState = ProcessGuardianJournalState()
                activeSessionID = nil
                activeOwner = nil
                lastRevision = 0
                resetSessionAfterRecovery = false
            } else {
                try persistCurrentSession(
                    tracked: unresolved,
                    automaticResumeIntervals: intervals
                )
            }
            automaticResumeStates = automaticResumeStates.filter {
                unresolved.contains($0.key)
            }
            if unresolved.isEmpty || resetSessionAfterRecovery {
                leaseDeadlineNanoseconds = nil
            }
            blockingError = unresolved.isEmpty
                ? nil
                : "The process guardian could not restore every managed process."
        } catch {
            blockingError = error.localizedDescription
        }

        if blockingError != nil || !unresolved.isEmpty {
            recoveryRetryDeadlineNanoseconds = Self.addingWithoutOverflow(
                clock(),
                Self.retryDelayNanoseconds
            )
        } else {
            recoveryRetryDeadlineNanoseconds = nil
        }
        scheduleTimer()
        return result
    }

    private func attemptPendingRecovery(now: UInt64) {
        guard let recoveryRetryDeadlineNanoseconds,
              recoveryRetryDeadlineNanoseconds <= now,
              !journalState.trackedProcesses.isEmpty else {
            return
        }
        _ = recoverAll(resetSession: false)
    }

    private func refreshLease(now: UInt64) {
        leaseDeadlineNanoseconds = Self.addingWithoutOverflow(
            now,
            leaseDurationNanoseconds
        )
    }

    private func scheduleTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil

        let deadlines = [
            journalState.trackedProcesses.isEmpty ? nil : leaseDeadlineNanoseconds,
            automaticResumeStates.values.map(\.deadlineNanoseconds).min(),
            recoveryRetryDeadlineNanoseconds,
        ].compactMap { $0 }
        guard let nextDeadline = deadlines.min() else { return }

        let now = clock()
        let delay = nextDeadline > now ? nextDeadline - now : 0
        let boundedDelay = min(delay, UInt64(Int.max))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(boundedDelay)))
        timer.setEventHandler { [weak self] in
            self?.timerFired()
        }
        self.timer = timer
        timer.activate()
    }

    private func timerFired() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        let now = clock()

        if let recoveryRetryDeadlineNanoseconds,
           recoveryRetryDeadlineNanoseconds <= now {
            attemptPendingRecovery(now: now)
        }

        if let leaseDeadlineNanoseconds,
           !journalState.trackedProcesses.isEmpty,
           leaseDeadlineNanoseconds <= now {
            _ = recoverAll(resetSession: true)
            invalidateConnection?()
            return
        }

        let processesToResume = Set(automaticResumeStates.compactMap {
            process, state in
            state.deadlineNanoseconds <= now && state.phase == .stopped
                ? process
                : nil
        })
        if !processesToResume.isEmpty {
            let result = Self.resumeWithRetries(
                processesToResume,
                attempts: Self.recoveryAttempts,
                retryMicroseconds: 10_000
            )
            if !result.failed.isEmpty {
                _ = recoverAll(resetSession: true)
                invalidateConnection?()
                return
            }
            let resumedAt = clock()
            for process in result.stale {
                automaticResumeStates.removeValue(forKey: process)
            }
            for process in result.applied {
                guard let state = automaticResumeStates[process] else { continue }
                automaticResumeStates[process] = GuardianAutomaticResumeState(
                    deadlineNanoseconds: Self.addingWithoutOverflow(
                        resumedAt,
                        Self.runIntervalNanoseconds(
                            stopIntervalNanoseconds: state.intervalNanoseconds
                        )
                    ),
                    intervalNanoseconds: state.intervalNanoseconds,
                    phase: .running
                )
            }
        }

        let stopNow = clock()
        let processesToStop = Set(automaticResumeStates.compactMap {
            process, state in
            state.deadlineNanoseconds <= stopNow && state.phase == .running
                ? process
                : nil
        })
        if !processesToStop.isEmpty {
            let result = Self.applySignal(SIGSTOP, to: processesToStop)
            if !result.failed.isEmpty {
                _ = recoverAll(resetSession: true)
                invalidateConnection?()
                return
            }
            let stoppedAt = clock()
            for process in result.stale {
                automaticResumeStates.removeValue(forKey: process)
            }
            for process in result.applied {
                guard let state = automaticResumeStates[process] else { continue }
                automaticResumeStates[process] = GuardianAutomaticResumeState(
                    deadlineNanoseconds: Self.addingWithoutOverflow(
                        stoppedAt,
                        state.intervalNanoseconds
                    ),
                    intervalNanoseconds: state.intervalNanoseconds,
                    phase: .stopped
                )
            }
        }
        scheduleTimer()
    }

    static func runIntervalNanoseconds(
        stopIntervalNanoseconds: UInt64
    ) -> UInt64 {
        let boundedStop = min(
            stopIntervalNanoseconds,
            pulsePeriodNanoseconds
        )
        return max(
            minimumRunNanoseconds,
            pulsePeriodNanoseconds - boundedStop
        )
    }

    private func synchronizeAutomaticResumeDeadlines(
        intervals: [WatchdogProcessIdentity: UInt32],
        resetProcesses: Set<WatchdogProcessIdentity>,
        replacesAll: Bool
    ) {
        if replacesAll {
            automaticResumeStates = automaticResumeStates.filter {
                intervals[$0.key] != nil
            }
        }
        let now = clock()
        for (process, milliseconds) in intervals {
            let interval = UInt64(milliseconds) * 1_000_000
            if resetProcesses.contains(process)
                || automaticResumeStates[process] == nil {
                automaticResumeStates[process] = GuardianAutomaticResumeState(
                    deadlineNanoseconds: Self.addingWithoutOverflow(now, interval),
                    intervalNanoseconds: interval,
                    phase: .stopped
                )
            } else if let prior = automaticResumeStates[process] {
                automaticResumeStates[process] = GuardianAutomaticResumeState(
                    deadlineNanoseconds: prior.deadlineNanoseconds,
                    intervalNanoseconds: interval,
                    phase: prior.phase
                )
            }
        }
    }

    private func classifyForStop(
        _ processes: Set<WatchdogProcessIdentity>,
        owner: WatchdogProcessIdentity
    ) -> GuardianOperationResult {
        var result = GuardianOperationResult()
        for process in processes {
            guard Self.currentIdentity(for: process.pid) == process else {
                result.stale.insert(process)
                continue
            }
            guard process.pid != getpid(),
                  process != owner,
                  Self.isUserOwned(process.pid),
                  !Self.isProtected(process.pid) else {
                result.failed.insert(process)
                continue
            }
            result.applied.insert(process)
        }
        return result
    }

    private func classifyForTracking(
        _ processes: Set<WatchdogProcessIdentity>,
        owner: WatchdogProcessIdentity
    ) -> GuardianOperationResult {
        var result = GuardianOperationResult()
        for process in processes {
            guard Self.currentIdentity(for: process.pid) == process else {
                result.stale.insert(process)
                continue
            }
            guard process.pid != getpid(),
                  process != owner,
                  Self.isUserOwned(process.pid) else {
                result.failed.insert(process)
                continue
            }
            result.applied.insert(process)
        }
        return result
    }

    private func rejectedStopResult(
        _ classification: GuardianOperationResult
    ) -> GuardianOperationResult {
        GuardianOperationResult(
            stale: classification.stale,
            failed: classification.applied.union(classification.failed)
        )
    }

    private func currentAutomaticResumeIntervals()
        -> [WatchdogProcessIdentity: UInt32] {
        Dictionary(uniqueKeysWithValues: journalState.automaticResumeIntervals.map {
            ($0.process, $0.resumeAfterMilliseconds)
        })
    }

    private func persist(
        tracked: Set<WatchdogProcessIdentity>,
        automaticResumeIntervals: [WatchdogProcessIdentity: UInt32],
        request: ProcessGuardianRequest
    ) throws {
        let state: ProcessGuardianJournalState
        if tracked.isEmpty {
            guard automaticResumeIntervals.isEmpty else {
                throw ProcessGuardianJournalError.invalidState
            }
            state = ProcessGuardianJournalState()
        } else {
            state = ProcessGuardianJournalState(
                sessionID: request.sessionID,
                revision: request.revision,
                owner: request.owner,
                trackedProcesses: Self.sorted(tracked),
                automaticResumeIntervals: Self.sorted(automaticResumeIntervals)
            )
        }
        try journalStore.save(state)
        journalState = state
    }

    private func persistCurrentSession(
        tracked: Set<WatchdogProcessIdentity>,
        automaticResumeIntervals: [WatchdogProcessIdentity: UInt32]
    ) throws {
        if tracked.isEmpty {
            guard automaticResumeIntervals.isEmpty else {
                throw ProcessGuardianJournalError.invalidState
            }
            try journalStore.save(ProcessGuardianJournalState())
            journalState = ProcessGuardianJournalState()
            return
        }
        guard let activeSessionID, let activeOwner else {
            throw ProcessGuardianJournalError.invalidState
        }
        let state = ProcessGuardianJournalState(
            sessionID: activeSessionID,
            revision: lastRevision,
            owner: activeOwner,
            trackedProcesses: Self.sorted(tracked),
            automaticResumeIntervals: Self.sorted(automaticResumeIntervals)
        )
        try journalStore.save(state)
        journalState = state
    }

    private func success(
        _ request: ProcessGuardianRequest
    ) -> ProcessGuardianResponse {
        ProcessGuardianResponse(
            sessionID: request.sessionID,
            requestID: request.requestID,
            revision: request.revision,
            guardianInstanceID: guardianInstanceID
        )
    }

    private func resultResponse(
        _ request: ProcessGuardianRequest,
        result: GuardianOperationResult
    ) -> ProcessGuardianResponse {
        ProcessGuardianResponse(
            sessionID: request.sessionID,
            requestID: request.requestID,
            revision: request.revision,
            guardianInstanceID: guardianInstanceID,
            applied: Self.sorted(result.applied),
            stale: Self.sorted(result.stale),
            failed: Self.sorted(result.failed)
        )
    }

    private func failure(
        _ request: ProcessGuardianRequest,
        code: ProcessGuardianErrorCode,
        message: String,
        failed: Set<WatchdogProcessIdentity> = []
    ) -> ProcessGuardianResponse {
        ProcessGuardianResponse(
            sessionID: request.sessionID,
            requestID: request.requestID,
            revision: request.revision,
            guardianInstanceID: guardianInstanceID,
            failed: Self.sorted(failed),
            errorCode: code,
            errorMessage: message
        )
    }

    private static func resumeWithRetries(
        _ processes: Set<WatchdogProcessIdentity>,
        attempts: Int,
        retryMicroseconds: useconds_t
    ) -> GuardianOperationResult {
        var aggregate = GuardianOperationResult()
        var unresolved = processes
        for attempt in 0..<max(1, attempts) where !unresolved.isEmpty {
            let result = applySignal(SIGCONT, to: unresolved)
            aggregate.applied.formUnion(result.applied)
            aggregate.stale.formUnion(result.stale)
            unresolved = result.failed
            if !unresolved.isEmpty, attempt + 1 < attempts {
                usleep(retryMicroseconds)
            }
        }
        aggregate.failed = unresolved
        return aggregate
    }

    private static func applySignal(
        _ signal: Int32,
        to processes: Set<WatchdogProcessIdentity>
    ) -> GuardianOperationResult {
        var result = GuardianOperationResult()
        for process in processes {
            guard currentIdentity(for: process.pid) == process else {
                result.stale.insert(process)
                continue
            }
            if kill(process.pid, signal) == 0 {
                result.applied.insert(process)
            } else {
                result.failed.insert(process)
            }
        }
        return result
    }

    private static func currentIdentity(
        for pid: pid_t
    ) -> WatchdogProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard readSize == expectedSize else { return nil }

        let seconds = UInt64(info.pbi_start_tvsec)
        let microseconds = UInt64(info.pbi_start_tvusec)
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !multiplied.overflow else { return nil }
        let added = multiplied.partialValue.addingReportingOverflow(microseconds)
        guard !added.overflow else { return nil }
        return WatchdogProcessIdentity(
            pid: pid,
            startTimeMicroseconds: added.partialValue
        )
    }

    private static func isUserOwned(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        return readSize == expectedSize && info.pbi_uid == geteuid()
    }

    private static func isProtected(_ pid: pid_t) -> Bool {
        var pathBytes = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(pid, &pathBytes, UInt32(pathBytes.count))
        guard pathLength > 0,
              Int(pathLength) <= pathBytes.count else {
            return true
        }
        var pathUTF8 = pathBytes.prefix(Int(pathLength)).map {
            UInt8(bitPattern: $0)
        }
        if pathUTF8.last == 0 {
            pathUTF8.removeLast()
        }
        guard !pathUTF8.isEmpty else { return true }
        return ProtectedSystemProcessPolicy.isProtectedExecutablePath(
            String(decoding: pathUTF8, as: UTF8.self)
        )
    }

    private static func addingWithoutOverflow(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let addition = lhs.addingReportingOverflow(rhs)
        return addition.overflow ? .max : addition.partialValue
    }

    private static func sorted(
        _ processes: Set<WatchdogProcessIdentity>
    ) -> [WatchdogProcessIdentity] {
        processes.sorted(by: identityOrder)
    }

    private static func sorted(
        _ intervals: [WatchdogProcessIdentity: UInt32]
    ) -> [WatchdogResumeDeadline] {
        intervals.map { process, milliseconds in
            WatchdogResumeDeadline(
                process: process,
                resumeAfterMilliseconds: milliseconds
            )
        }.sorted { identityOrder($0.process, $1.process) }
    }

    private static func identityOrder(
        _ first: WatchdogProcessIdentity,
        _ second: WatchdogProcessIdentity
    ) -> Bool {
        if first.pid != second.pid { return first.pid < second.pid }
        return first.startTimeMicroseconds < second.startTimeMicroseconds
    }
}

private final class ProcessGuardianSession:
    NSObject, ProcessGuardianXPCProtocol, @unchecked Sendable {
    private let controller: ProcessGuardianStateController
    private weak var connection: NSXPCConnection?
    private let connectionPID: pid_t
    private let lock = NSLock()
    private var sessionID: UUID?
    private var isInvalidated = false

    init(
        controller: ProcessGuardianStateController,
        connection: NSXPCConnection
    ) {
        self.controller = controller
        self.connection = connection
        connectionPID = connection.processIdentifier
    }

    func send(
        _ requestData: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    ) {
        guard requestData.count <= ProcessGuardianProtocol.maximumFrameBytes,
              let request = try? JSONDecoder().decode(
                  ProcessGuardianRequest.self,
                  from: requestData
              ),
              request.isValid else {
            reply(Data())
            return
        }

        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            reply(Data())
            return
        }
        if let sessionID, sessionID != request.sessionID {
            lock.unlock()
            reply(Data())
            return
        }
        sessionID = request.sessionID
        // Queue the request before invalidation can queue its recovery operation.
        controller.handle(
            request,
            connectionPID: connectionPID,
            invalidateConnection: { [weak self] in
                self?.invalidateConnection()
            },
            reply: { response in
                let encoded = try? JSONEncoder().encode(response)
                reply(encoded ?? Data())
            }
        )
        lock.unlock()
    }

    func invalidateConnection() {
        lock.lock()
        let connection = connection
        lock.unlock()
        connection?.invalidate()
    }

    func invalidate(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            completion()
            return
        }
        isInvalidated = true
        let sessionID = sessionID
        lock.unlock()

        guard let sessionID else {
            completion()
            return
        }
        controller.connectionInvalidated(
            sessionID: sessionID,
            completion: completion
        )
    }
}

private final class ProcessGuardianListenerDelegate:
    NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let controller: ProcessGuardianStateController
    private var activeConnection: NSXPCConnection?
    private var activeConnectionID: UUID?

    init(controller: ProcessGuardianStateController) {
        self.controller = controller
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }

        lock.lock()
        defer { lock.unlock() }
        guard activeConnection == nil else { return false }

        let connectionID = UUID()
        let session = ProcessGuardianSession(
            controller: controller,
            connection: connection
        )
        connection.exportedInterface = NSXPCInterface(
            with: ProcessGuardianXPCProtocol.self
        )
        connection.exportedObject = session
        connection.interruptionHandler = { [weak session] in
            session?.invalidateConnection()
        }
        connection.invalidationHandler = { [weak self] in
            session.invalidate { [weak self] in
                guard let self else { return }
                lock.lock()
                if activeConnectionID == connectionID {
                    activeConnection = nil
                    activeConnectionID = nil
                }
                lock.unlock()
            }
        }
        activeConnection = connection
        activeConnectionID = connectionID
        connection.activate()
        return true
    }
}

private enum ProcessGuardianRequirementResult: Sendable {
    case success(String)
    case failure
}

private final class ProcessGuardianRequirementGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ProcessGuardianRequirementResult?

    func store(_ result: ProcessGuardianRequirementResult) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> ProcessGuardianRequirementResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

enum ProcessGuardianService {
    static func run() -> Int32 {
        let journalStore: ProcessGuardianJournalStore
        do {
            journalStore = try .live()
        } catch {
            return EXIT_FAILURE
        }
        let controller = ProcessGuardianStateController(
            journalStore: journalStore
        )
        controller.start()
        let listener = NSXPCListener(
            machServiceName: ProcessGuardianProtocol.machServiceName
        )
        let requirementGate = ProcessGuardianRequirementGate()
        let requirementReady = DispatchSemaphore(value: 0)
        // Run the Security framework check before the main dispatch loop starts.
        DispatchQueue.global(qos: .utility).async {
            let result: ProcessGuardianRequirementResult
            do {
                result = .success(
                    try TempraCodeSigningRequirement.peerRequirement(
                        identifier: ProcessGuardianProtocol.applicationIdentifier
                    )
                )
            } catch {
                result = .failure
            }
            requirementGate.store(result)
            requirementReady.signal()
        }
        requirementReady.wait()
        guard case .success(let requirement) = requirementGate.load() else {
            return EXIT_FAILURE
        }
        listener.setConnectionCodeSigningRequirement(requirement)
        let delegate = ProcessGuardianListenerDelegate(controller: controller)
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime(delegate) {
            dispatchMain()
        }
    }
}
