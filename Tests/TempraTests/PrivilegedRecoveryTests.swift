import Testing
@testable import TempraPrivilegedHelper
import TempraSafety

@Suite("Privileged recovery")
struct PrivilegedRecoveryTests {
    @Test("A new helper session accepts processes recovered after disconnect")
    func recoveredProcessesResolveWithoutAnotherSignal() {
        let processes = Set([identity(4_001), identity(4_002), identity(4_003)])
        var report = PrivilegedRecoveryReport(resumed: processes)
        var signalCount = 0

        let result = report.resolveResumes(
            processes,
            identityIsCurrent: { _ in true },
            resume: { _ in
                signalCount += 1
                return true
            }
        )

        #expect(result.applied == processes)
        #expect(result.stale.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(signalCount == 0)
    }

    @Test("A failed disconnect resume is retried with exact ownership")
    func failedResumeIsRetried() {
        let process = identity(4_004)
        var report = PrivilegedRecoveryReport(failedResumes: [process])

        let result = report.resolveResumes(
            [process],
            identityIsCurrent: { $0 == process },
            resume: { $0 == process }
        )

        #expect(result.applied == [process])
        #expect(result.stale.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(report.resumed == [process])
        #expect(report.failedResumes.isEmpty)
    }

    @Test("A stale disconnect resume does not target a reused process identifier")
    func staleResumeIsNotRetried() {
        let process = identity(4_005)
        var report = PrivilegedRecoveryReport(failedResumes: [process])
        var didSignal = false

        let result = report.resolveResumes(
            [process],
            identityIsCurrent: { _ in false },
            resume: { _ in
                didSignal = true
                return true
            }
        )

        #expect(result.applied.isEmpty)
        #expect(result.stale == [process])
        #expect(result.failed.isEmpty)
        #expect(!didSignal)
        #expect(report.staleResumes == [process])
    }

    @Test("A failed priority recovery keeps the original policy for retry")
    func failedPriorityRestoreIsRetried() {
        let process = identity(4_006)
        let originalPriority = ProcessPriorityPolicyState(niceValue: 2)
        var report = PrivilegedRecoveryReport(
            failedPriorities: [process: originalPriority]
        )
        var restoredPolicy: ProcessPriorityPolicyState?

        let result = report.resolvePriorities(
            [process],
            identityIsCurrent: { $0 == process },
            restore: { restoredProcess, policy in
                #expect(restoredProcess == process)
                restoredPolicy = policy
                return true
            }
        )

        #expect(result.applied == [process])
        #expect(result.stale.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(restoredPolicy == originalPriority)
        #expect(report.restoredPriorities == [process])
        #expect(report.failedPriorities.isEmpty)
    }

    @Test("Acknowledgement removes completed recovery state")
    func acknowledgementRemovesCompletedRecovery() {
        let resumed = identity(4_007)
        let restoredPriority = identity(4_008)
        var report = PrivilegedRecoveryReport(
            resumed: [resumed],
            restoredPriorities: [restoredPriority]
        )

        report.removeResumeState(for: [resumed])
        report.removePriorityState(for: [restoredPriority])

        #expect(report.resumeProcesses.isEmpty)
        #expect(report.priorityProcesses.isEmpty)
    }

    private func identity(_ pid: Int32) -> PrivilegedProcessIdentity {
        PrivilegedProcessIdentity(
            pid: pid,
            startTimeMicroseconds: UInt64(pid) * 1_000
        )
    }
}
