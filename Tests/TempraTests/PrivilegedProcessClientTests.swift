import TempraSafety
import Testing

@testable import Tempra

@Suite("Privileged process client response mapping")
struct PrivilegedProcessClientTests {
    @Test("Operation errors preserve completed sets and fail only omitted identities")
    func mapsPartialOperationError() throws {
        let applied = identity(pid: 5_001)
        let unchanged = identity(pid: 5_002)
        let failed = identity(pid: 5_003)
        let omitted = identity(pid: 5_004)
        let detail = "the helper restored the managed state"
        let response = PrivilegedProcessResponse(
            applied: [remote(applied)],
            failed: [remote(failed)],
            unchanged: [remote(unchanged)],
            errorCode: .safetyHelperFailed,
            errorMessage: detail
        )

        let mapped = try PrivilegedProcessClient.mapOperationResponse(
            response,
            requested: [applied, unchanged, failed, omitted]
        )

        #expect(mapped.result.applied == [applied])
        #expect(mapped.result.stale.isEmpty)
        #expect(mapped.result.failed == [failed, omitted])
        #expect(mapped.result.failureDescription == detail)
        #expect(mapped.resolvedWithoutAction == [unchanged])
    }

    @Test("A recovery-success error response can resolve every requested identity")
    func mapsRecoverySuccessWithoutUnresolvedProcesses() throws {
        let processes = [identity(pid: 5_005), identity(pid: 5_006)]
        let response = PrivilegedProcessResponse(
            unchanged: processes.map(remote),
            errorCode: .safetyHelperFailed,
            errorMessage: "managed state was restored"
        )

        let mapped = try PrivilegedProcessClient.mapOperationResponse(
            response,
            requested: Set(processes)
        )

        #expect(mapped.result.applied.isEmpty)
        #expect(mapped.result.stale.isEmpty)
        #expect(mapped.result.failed.isEmpty)
        #expect(mapped.resolvedWithoutAction == Set(processes))
    }

    @Test("Overlapping or unexpected operation identities remain invalid")
    func rejectsMalformedOperationResponse() {
        let first = identity(pid: 5_007)
        let second = identity(pid: 5_008)
        let requested = Set([first, second])
        let overlapping = PrivilegedProcessResponse(
            applied: [remote(first)],
            unchanged: [remote(first)],
            errorCode: .operationFailed,
            errorMessage: "partial"
        )
        let unexpected = PrivilegedProcessResponse(
            applied: [remote(identity(pid: 5_009))],
            errorCode: .operationFailed,
            errorMessage: "partial"
        )

        #expect(throws: PrivilegedProcessClientError.self) {
            try PrivilegedProcessClient.mapOperationResponse(
                overlapping,
                requested: requested
            )
        }
        #expect(throws: PrivilegedProcessClientError.self) {
            try PrivilegedProcessClient.mapOperationResponse(
                unexpected,
                requested: requested
            )
        }
    }

    private func identity(pid: Int32) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            startTimeMicroseconds: UInt64(pid) * 1_000,
            requiresPrivilegedControl: true
        )
    }

    private func remote(_ process: ProcessIdentity) -> PrivilegedProcessIdentity {
        PrivilegedProcessIdentity(
            pid: Int32(process.pid),
            startTimeMicroseconds: process.startTimeMicroseconds
        )
    }
}
