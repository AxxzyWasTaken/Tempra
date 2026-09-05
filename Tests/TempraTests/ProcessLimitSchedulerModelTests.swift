import Foundation
import Testing
@testable import Tempra

@Suite("Process limit scheduler model")
struct ProcessLimitSchedulerModelTests {
    @Test("A fresh runtime seeds from the sampled usage")
    func freshRuntimeSeedsFromSample() {
        let now = ContinuousClock().now
        let process = ProcessIdentity(pid: 10, startTimeMicroseconds: 1)

        let below = ProcessLimitSchedulerModel.Runtime.advancing(
            nil,
            to: now,
            cpuNanoseconds: 0,
            sampledCPUPercent: 5,
            limitPercent: 10,
            processIdentities: [process]
        )
        #expect(below.phase == .observing)
        #expect(!below.hasActivatedLimit)
        #expect(below.dutyFactor == 0)
        #expect(below.generation == 1)

        let above = ProcessLimitSchedulerModel.Runtime.advancing(
            nil,
            to: now,
            cpuNanoseconds: 0,
            sampledCPUPercent: 100,
            limitPercent: 10,
            processIdentities: [process]
        )
        #expect(above.phase == .running)
        #expect(above.hasActivatedLimit)
        #expect(above.estimatedFullSpeedCPU == 100)
        #expect(abs(above.dutyFactor - 0.09) < 0.0001)
    }

    @Test("An advanced runtime measures CPU from the counter delta")
    func advancedRuntimeMeasuresFromCounterDelta() {
        let start = ContinuousClock().now
        let process = ProcessIdentity(pid: 11, startTimeMicroseconds: 1)
        let first = ProcessLimitSchedulerModel.Runtime.advancing(
            nil,
            to: start,
            cpuNanoseconds: 0,
            sampledCPUPercent: 20,
            limitPercent: 10,
            processIdentities: [process]
        )

        // 50ms of CPU over 100ms of wall time is 50%.
        let second = ProcessLimitSchedulerModel.Runtime.advancing(
            first,
            to: start.advanced(by: .milliseconds(100)),
            cpuNanoseconds: 50_000_000,
            sampledCPUPercent: 999,
            limitPercent: 10,
            processIdentities: [process]
        )
        #expect(second.lastMeasuredCPUPercent == 50)
        #expect(second.estimatedFullSpeedCPU == 50)
        #expect(second.generation == 2)
        #expect(second.hasActivatedLimit)
        #expect(second.lastCPUNanoseconds == 50_000_000)

        // A counter that went backwards falls back to the sample.
        let regressed = ProcessLimitSchedulerModel.Runtime.advancing(
            second,
            to: start.advanced(by: .milliseconds(200)),
            cpuNanoseconds: 1,
            sampledCPUPercent: 30,
            limitPercent: 10,
            processIdentities: [process]
        )
        #expect(regressed.lastMeasuredCPUPercent == 30)
        // The full-speed estimate never shrinks within a runtime.
        #expect(regressed.estimatedFullSpeedCPU == 50)
    }

    @Test("The pulse arbiter staggers ordinary apps")
    func staggersOrdinaryApps() {
        let now = ContinuousClock().now
        let firstEnd = now.advanced(by: .milliseconds(5))
        var arbiter = ProcessLimitSchedulerModel.PulseArbiter()

        let first = arbiter.decision(
            for: .init(
                identifier: "first.app",
                generation: 1,
                requestedAt: now,
                latestStart: now.advanced(by: .milliseconds(500)),
                isLatencySensitive: false
            ),
            minimumGap: .milliseconds(1)
        )
        guard case .start(overlapsExistingPulse: false) = first else {
            Issue.record("The first pulse did not start immediately.")
            return
        }
        arbiter.acquire(identifier: "first.app", generation: 1, expectedEnd: firstEnd)

        let second = arbiter.decision(
            for: .init(
                identifier: "second.app",
                generation: 1,
                requestedAt: now,
                latestStart: now.advanced(by: .milliseconds(500)),
                isLatencySensitive: false
            ),
            minimumGap: .milliseconds(1)
        )
        guard case .deferUntil(let deferredUntil) = second else {
            Issue.record("The second ordinary pulse was allowed to overlap.")
            return
        }
        #expect(deferredUntil >= firstEnd.advanced(by: .milliseconds(1)))

        arbiter.release(identifier: "first.app", generation: 1)
        #expect(arbiter.activeCount == 0)
    }

    @Test("A network deadline can override pulse serialization")
    func networkDeadlineCanOverrideSerialization() {
        let now = ContinuousClock().now
        var arbiter = ProcessLimitSchedulerModel.PulseArbiter()
        arbiter.acquire(
            identifier: "offline.app",
            generation: 1,
            expectedEnd: now.advanced(by: .milliseconds(5))
        )

        let decision = arbiter.decision(
            for: .init(
                identifier: "game.app",
                generation: 1,
                requestedAt: now,
                latestStart: now.advanced(by: .milliseconds(2)),
                isLatencySensitive: true
            ),
            minimumGap: .milliseconds(1)
        )
        guard case .start(overlapsExistingPulse: true) = decision else {
            Issue.record("The network service deadline was not honored.")
            return
        }
    }
}
