import Foundation
import Testing
@testable import Tempra

@Suite("Process limit scheduler model")
struct ProcessLimitSchedulerModelTests {
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
