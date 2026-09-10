import Darwin
import Foundation
import Testing
@testable import Tempra
import TempraSafety

@Suite("Process system routing")
struct ProcessSystemControllerTests {
    @Test("User-owned stopping uses a direct signal")
    func userOwnedStoppingUsesDirectSignal() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["10"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        defer {
            _ = kill(pid, SIGCONT)
            if sleeper.isRunning {
                sleeper.terminate()
                sleeper.waitUntilExit()
            }
        }

        let identity = try #require(
            LiveProcessSystemController.currentIdentity(for: pid)
        )
        let controller = LiveProcessSystemController()

        let result = await controller.stop(
            [identity],
            automaticResumeAfter: 0.1
        )

        #expect(result.applied == [identity])
        #expect(result.stale.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(await eventuallyStatus(of: pid, isStopped: true))
    }

    @Test("Local signals use kernel identity, not routing metadata")
    func localSignalsIgnorePrivilegedRoutingMetadata() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["10"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        defer {
            _ = kill(pid, SIGCONT)
            if sleeper.isRunning {
                sleeper.terminate()
                sleeper.waitUntilExit()
            }
        }

        let current = try #require(
            LiveProcessSystemController.currentIdentity(for: pid)
        )
        let identity = ProcessIdentity(
            pid: current.pid,
            startTimeMicroseconds: current.startTimeMicroseconds,
            requiresPrivilegedControl: true
        )
        let controller = LiveProcessSystemController()

        let result = await controller.stop(
            [identity],
            automaticResumeAfter: nil
        )

        #expect(result.applied == [identity])
        #expect(result.stale.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(await eventuallyStatus(of: pid, isStopped: true))

        let restoration = await controller.resume([identity])
        #expect(restoration.applied == [identity])
        #expect(restoration.stale.isEmpty)
        #expect(restoration.failed.isEmpty)
        #expect(await eventuallyStatus(of: pid, isStopped: false))
    }

    @Test("User-owned restoration does not depend on the process guardian")
    func userOwnedRestorationUsesDirectSignal() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["10"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        defer {
            _ = kill(pid, SIGCONT)
            if sleeper.isRunning {
                sleeper.terminate()
                sleeper.waitUntilExit()
            }
        }

        let identity = try #require(
            LiveProcessSystemController.currentIdentity(for: pid)
        )
        try #require(kill(pid, SIGSTOP) == 0)
        #expect(await eventuallyStatus(of: pid, isStopped: true))

        let controller = LiveProcessSystemController()
        let result = await controller.resume([identity])

        #expect(result.applied == [identity])
        #expect(result.stale.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(await eventuallyStatus(of: pid, isStopped: false))
    }

    @Test("Exited processes do not require privileged priority restoration")
    func exitedProcessesDoNotRequirePrivilegedPriorityRestoration() async {
        let staleProcess = ProcessIdentity(
            pid: getpid(),
            startTimeMicroseconds: 0
        )
        let controller = RoutedProcessSystemController()

        let result = await controller.restorePriority([staleProcess])

        #expect(result.applied.isEmpty)
        #expect(result.stale == [staleProcess])
        #expect(result.failed.isEmpty)
        #expect(result.failureDescription == nil)
    }

    @Test("Same-user backgrounding journals with the guardian before touching the process")
    func sameUserBackgroundingJournalsFirst() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["10"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        defer {
            if sleeper.isRunning {
                sleeper.terminate()
                sleeper.waitUntilExit()
            }
        }
        let identity = try #require(
            LiveProcessSystemController.currentIdentity(for: pid)
        )
        let journal = RecordingBackgroundJournal()
        let controller = RoutedProcessSystemController(backgroundJournal: journal)

        let lowered = await controller.lowerPriority([identity])

        #expect(lowered.applied == [identity])
        #expect(lowered.failed.isEmpty)
        #expect(journal.prepared == [[identity]])
        #expect(journal.preparedBeforeBackgrounded == true)
        #expect(try ProcessPriorityController().state(for: pid).isBackgrounded)

        let restored = await controller.restorePriority([identity])

        #expect(restored.applied == [identity])
        #expect(restored.failed.isEmpty)
        #expect(try !ProcessPriorityController().state(for: pid).isBackgrounded)
        #expect(journal.synchronized == [[]])
    }

    @Test("A journal failure leaves the process untouched and falls back to the helper")
    func journalFailureFallsBackToHelper() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["10"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        defer {
            if sleeper.isRunning {
                sleeper.terminate()
                sleeper.waitUntilExit()
            }
        }
        let identity = try #require(
            LiveProcessSystemController.currentIdentity(for: pid)
        )
        let journal = RecordingBackgroundJournal()
        journal.prepareError = ProcessGuardianClientError.serviceNotEnabled
        let controller = RoutedProcessSystemController(backgroundJournal: journal)

        let lowered = await controller.lowerPriority([identity])

        // No helper is installed in tests, so the fallback fails, but the
        // process must never have been backgrounded without a journal entry.
        #expect(lowered.applied.isEmpty)
        #expect(lowered.failed == [identity])
        #expect(try !ProcessPriorityController().state(for: pid).isBackgrounded)
    }

    @Test("The limit pulse resolves current processes without touching them")
    func limitPulseIsANoOpLocally() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["10"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        defer {
            if sleeper.isRunning {
                sleeper.terminate()
                sleeper.waitUntilExit()
            }
        }
        let identity = try #require(
            LiveProcessSystemController.currentIdentity(for: pid)
        )
        let stale = ProcessIdentity(pid: pid, startTimeMicroseconds: 1)
        let journal = RecordingBackgroundJournal()
        let controller = RoutedProcessSystemController(backgroundJournal: journal)

        let result = await controller.applyLimitPriority([identity, stale])

        #expect(result.applied.isEmpty)
        #expect(result.stale == [stale])
        #expect(result.failed.isEmpty)
        #expect(journal.prepared.isEmpty)
        #expect(try !ProcessPriorityController().state(for: pid).isBackgrounded)
    }

    private func eventuallyStatus(
        of pid: pid_t,
        isStopped expectedStatus: Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if let info = LiveProcessSystemController.bsdInfo(for: pid),
               (UInt32(info.pbi_status) == UInt32(SSTOP)) == expectedStatus {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private final class RecordingBackgroundJournal: ProcessBackgroundJournaling, @unchecked Sendable {
    private let lock = NSLock()
    private var preparedRecord: [Set<ProcessIdentity>] = []
    private var synchronizedRecord: [Set<ProcessIdentity>] = []
    private var backgroundedAtPrepare: [Bool] = []
    var prepareError: (any Error)?

    var prepared: [Set<ProcessIdentity>] {
        lock.lock(); defer { lock.unlock() }
        return preparedRecord
    }

    var synchronized: [Set<ProcessIdentity>] {
        lock.lock(); defer { lock.unlock() }
        return synchronizedRecord
    }

    /// True when, at the moment of every prepare call, none of the requested
    /// processes were backgrounded yet: the journal came first.
    var preparedBeforeBackgrounded: Bool {
        lock.lock(); defer { lock.unlock() }
        return backgroundedAtPrepare.allSatisfy { !$0 }
    }

    func prepareBackground(_ processes: Set<ProcessIdentity>) async throws {
        if let prepareError { throw prepareError }
        let anyBackgrounded = processes.contains {
            (try? ProcessPriorityController().state(for: $0.pid).isBackgrounded) ?? false
        }
        record { preparedRecord.append(processes); backgroundedAtPrepare.append(anyBackgrounded) }
    }

    func synchronizeBackground(_ processes: Set<ProcessIdentity>) async throws {
        record { synchronizedRecord.append(processes) }
    }

    private func record(_ mutation: () -> Void) {
        lock.lock()
        mutation()
        lock.unlock()
    }
}
