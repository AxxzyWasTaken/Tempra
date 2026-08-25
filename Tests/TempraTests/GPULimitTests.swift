import Foundation
import Testing
@testable import Tempra

@Suite("GPU usage sampling")
struct GPUUsageSamplerTests {
    @Test("A busy nanosecond count converts to a share of one GPU")
    func percentConversion() {
        #expect(GPUUsageSampler.percent(
            busyNanoseconds: 500_000_000,
            elapsed: 1
        ) == 50)
        #expect(GPUUsageSampler.percent(
            busyNanoseconds: 250_000_000,
            elapsed: 0.5
        ) == 50)
    }

    @Test("Overlapping command queues cannot exceed one GPU")
    func percentIsCappedAtOneGPU() {
        #expect(GPUUsageSampler.percent(
            busyNanoseconds: 3_000_000_000,
            elapsed: 1
        ) == 100)
    }

    @Test("A zero or negative window reports no usage")
    func percentNeedsAWindow() {
        #expect(GPUUsageSampler.percent(busyNanoseconds: 1_000_000, elapsed: 0) == 0)
        #expect(GPUUsageSampler.percent(busyNanoseconds: 1_000_000, elapsed: -1) == 0)
    }

    @Test("The first sample only establishes a baseline")
    func firstSampleReportsZero() {
        var sampler = GPUUsageSampler()
        let first = sampler.sample(counters: [42: 900_000_000], at: 10)
        #expect(first[42] == 0)

        let second = sampler.sample(counters: [42: 1_800_000_000], at: 11)
        #expect(second[42] == 90)
    }

    @Test("A process that appears mid-run reports zero until its next sample")
    func newProcessReportsZeroOnce() {
        var sampler = GPUUsageSampler()
        _ = sampler.sample(counters: [1: 0], at: 10)
        let withNewProcess = sampler.sample(counters: [1: 0, 2: 5_000_000_000], at: 11)
        #expect(withNewProcess[2] == 0)

        let next = sampler.sample(counters: [1: 0, 2: 5_100_000_000], at: 12)
        #expect(next[2] == 10)
    }

    @Test("A counter reset reports zero instead of a negative delta")
    func counterResetReportsZero() {
        var sampler = GPUUsageSampler()
        _ = sampler.sample(counters: [7: 4_000_000_000], at: 10)
        _ = sampler.sample(counters: [7: 4_500_000_000], at: 11)
        let afterReset = sampler.sample(counters: [7: 10_000_000], at: 12)
        #expect(afterReset[7] == 0)
    }

    @Test("A repeated timestamp reports zero instead of dividing by nothing")
    func repeatedTimestampReportsZero() {
        var sampler = GPUUsageSampler()
        _ = sampler.sample(counters: [9: 0], at: 10)
        let repeated = sampler.sample(counters: [9: 1_000_000_000], at: 10)
        #expect(repeated[9] == 0)
    }

    @Test("The driver's client creator string yields the owning process")
    func creatorParsing() {
        #expect(LiveGPUUsageReader.processIdentifier(fromCreator: "pid 4213, Safari") == 4213)
        #expect(LiveGPUUsageReader.processIdentifier(
            fromCreator: "pid 413, WindowServer"
        ) == 413)
        #expect(LiveGPUUsageReader.processIdentifier(fromCreator: "pid 0, kernel") == nil)
        #expect(LiveGPUUsageReader.processIdentifier(fromCreator: "task 12, Safari") == nil)
        #expect(LiveGPUUsageReader.processIdentifier(fromCreator: "pid 12 Safari") == nil)
        #expect(LiveGPUUsageReader.processIdentifier(fromCreator: "") == nil)
    }
}

@Suite("GPU limit rules")
struct GPULimitRuleTests {
    @Test("A rule stored before GPU limits decodes without one")
    func legacyRuleDecodesWithoutGPULimit() throws {
        let stored = Data("""
        {
            "bundleIdentifier": "example.app",
            "displayName": "Example",
            "action": "limit",
            "limitPercent": 40,
            "delaySeconds": 0,
            "protectAudio": true,
            "onlyWhenHidden": false,
            "isEnabled": true
        }
        """.utf8)
        let rule = try JSONDecoder().decode(AppRule.self, from: stored)
        #expect(rule.limitPercent == 40)
        #expect(rule.gpuLimitWatts == nil)
    }

    @Test("A GPU ceiling survives an encode and decode round trip")
    func gpuLimitRoundTrips() throws {
        let rule = AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .limit,
            limitPercent: 40,
            gpuLimitWatts: 30,
            limitsGPUWhenInFront: true
        )
        let decoded = try JSONDecoder().decode(
            AppRule.self,
            from: try JSONEncoder().encode(rule)
        )
        #expect(decoded.gpuLimitWatts == 30)
        #expect(decoded.limitsGPUWhenInFront)
        #expect(decoded.limitPercent == 40)
    }

    @Test("A GPU ceiling only exists alongside a limit action")
    func gpuLimitNeedsALimitAction() {
        #expect(AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .pause,
            gpuLimitWatts: 30
        ).gpuLimitWatts == nil)
        #expect(AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .none,
            gpuLimitWatts: 30
        ).gpuLimitWatts == nil)
    }

    @Test("A GPU-only rule keeps the CPU ceiling switched off across a round trip")
    func gpuOnlyRuleRoundTrips() throws {
        let rule = AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .limit,
            limitsCPU: false,
            limitPercent: 40,
            gpuLimitWatts: 30
        )
        #expect(!rule.limitsCPU)
        #expect(rule.summary == "GPU 30 W")
        let decoded = try JSONDecoder().decode(
            AppRule.self,
            from: try JSONEncoder().encode(rule)
        )
        #expect(!decoded.limitsCPU)
        #expect(decoded.gpuLimitWatts == 30)
    }

    @Test("A rule without a GPU ceiling always limits the CPU")
    func withoutAGPUCeilingTheCPULimitStands() throws {
        let rule = AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .limit,
            limitsCPU: false,
            limitPercent: 40
        )
        #expect(rule.limitsCPU)

        let stored = Data("""
        {
            "bundleIdentifier": "example.app",
            "displayName": "Example",
            "action": "limit",
            "limitsCPU": false,
            "limitPercent": 40,
            "isEnabled": true
        }
        """.utf8)
        #expect(try JSONDecoder().decode(AppRule.self, from: stored).limitsCPU)
    }

    @Test("A GPU ceiling changes the limiter configuration on its own")
    func gpuOnlyChangesLimiterConfiguration() {
        let both = AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .limit,
            limitPercent: 40,
            gpuLimitWatts: 30
        )
        var gpuOnly = both
        gpuOnly.limitsCPU = false
        #expect(!both.hasSameLimiterConfiguration(as: gpuOnly))
    }

    @Test("Keeping the limit on in front needs a ceiling to keep")
    func inFrontNeedsACeiling() throws {
        #expect(!AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .limit,
            limitsGPUWhenInFront: true
        ).limitsGPUWhenInFront)

        let stored = Data("""
        {
            "bundleIdentifier": "example.app",
            "displayName": "Example",
            "action": "limit",
            "limitPercent": 40,
            "limitsGPUWhenInFront": true,
            "isEnabled": true
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(AppRule.self, from: stored)
        #expect(!decoded.limitsGPUWhenInFront)
    }

    @Test("A GPU ceiling changes the limiter configuration")
    func gpuLimitAffectsLimiterComparison() {
        let base = AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .limit,
            limitPercent: 40
        )
        var withCeiling = base
        withCeiling.gpuLimitWatts = 30
        var inFront = withCeiling
        inFront.limitsGPUWhenInFront = true
        #expect(!base.hasSameLimiterConfiguration(as: withCeiling))
        #expect(!withCeiling.hasSameLimiterConfiguration(as: inFront))
        #expect(withCeiling.hasSameLimiterConfiguration(as: withCeiling))
    }

    @Test("GPU share turns into watts through the measured power scale")
    func measuredScaleConvertsShareToWatts() throws {
        // 30 W spread over 90 share points costs one third of a watt per point.
        let scale = try #require(GPUPowerScale(totalWatts: 30, totalSharePercent: 90))
        #expect(abs(scale.wattsPerSharePoint - 1.0 / 3) < 0.000_001)
        #expect(abs(scale.watts(forSharePercent: 45) - 15) < 0.000_001)
        #expect(scale.watts(forSharePercent: 0) == 0)
        #expect(scale.watts(forSharePercent: -3) == 0)
    }

    @Test("An idle GPU gives no usable power scale")
    func idleGPUHasNoScale() {
        #expect(GPUPowerScale(totalWatts: 0.3, totalSharePercent: 0.4) == nil)
        #expect(GPUPowerScale(totalWatts: 0, totalSharePercent: 90) == nil)
        #expect(GPUPowerScale(totalWatts: .infinity, totalSharePercent: 90) == nil)
    }

    @Test("The observed power budget keeps the highest reading")
    func budgetTracksThePeak() {
        final class MovingPowerReader: GPUPowerReading, @unchecked Sendable {
            private let lock = NSLock()
            private var readings: [Double]

            init(readings: [Double]) {
                self.readings = readings
            }

            func currentWatts() -> Double? { 1 }

            func budgetWatts() -> Double? {
                lock.lock()
                defer { lock.unlock() }
                return readings.isEmpty ? nil : readings.removeFirst()
            }
        }

        // The firmware narrows the budget under load, so the peak is the ceiling.
        let budget = GPUPowerBudget(reader: MovingPowerReader(readings: [30, 113, 29]))
        #expect(budget.peakWatts == 30)
        #expect(budget.refresh() == 113)
        #expect(budget.refresh() == 113)
        #expect(budget.peakWatts == 113)
    }

    @Test("The offered range stops at this Mac's GPU ceiling")
    func rangeFollowsTheMachineCeiling() {
        let range = GPULimitRange.allowed(ceilingWatts: 113.2)
        #expect(range.lowerBound == GPULimitRange.minimumWatts)
        #expect(range.upperBound == 113)
        #expect(GPULimitRange.clamped(400, ceilingWatts: 113.2) == 113)
        #expect(GPULimitRange.clamped(0, ceilingWatts: 113.2) == GPULimitRange.minimumWatts)
    }
}

@Suite("GPU limit target selection")
struct GPULimitTargetSelectionTests {
    private func process(_ pid: pid_t) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeMicroseconds: UInt64(pid))
    }

    /// A GPU drawing 100 W while fully busy, so one share point costs one watt
    /// and the numbers below read as both.
    private let scale = GPUPowerScale(totalWatts: 100, totalSharePercent: 100)!

    @Test("The GPU pass stops the renderer that the CPU pass ignores")
    func gpuDemandSelectsTheGPUHeavyProcess() {
        let main = process(301)
        let renderer = process(302)
        let samples = [
            ManagedProcessSample(
                identity: main,
                cpuPercent: 20,
                gpuPercent: 1,
                isMainProcess: true
            ),
            ManagedProcessSample(
                identity: renderer,
                cpuPercent: 1,
                gpuPercent: 80,
                isMainProcess: false
            )
        ]

        let cpuSelection = ProcessLimitTargetSelector.select(
            samples: samples,
            limitPercent: 30
        )
        #expect(cpuSelection.controlledProcesses.isEmpty)
        #expect(cpuSelection.demand == .cpu)

        let gpuSelection = ProcessLimitTargetSelector.select(
            samples: samples.map { $0.scalingGPUShareToWatts(with: scale) },
            limitPercent: 30,
            demand: .gpu
        )
        #expect(gpuSelection.controlledProcesses == [renderer])
        #expect(gpuSelection.controlledDemand == 80)
        #expect(gpuSelection.demand == .gpu)
    }

    @Test("A GPU ceiling below the protected work is not reachable")
    func unreachableGPUCeiling() {
        let audio = process(311)
        let renderer = process(312)
        let samples = [
            ManagedProcessSample(
                identity: audio,
                cpuPercent: 2,
                gpuPercent: 40,
                isMainProcess: true,
                isPlayingAudio: true
            ),
            ManagedProcessSample(
                identity: renderer,
                cpuPercent: 2,
                gpuPercent: 40,
                isMainProcess: false
            )
        ]

        let selection = ProcessLimitTargetSelector.select(
            samples: samples.map { $0.scalingGPUShareToWatts(with: scale) },
            limitPercent: 20,
            demand: .gpu
        )
        #expect(selection.controlledProcesses == [renderer])
        #expect(!selection.targetIsReachable)
    }

    @Test("A single-process app is selected whenever its rule carries a ceiling")
    func singleProcessAppIsAlwaysSelected() {
        let renderer = process(321)
        let samples = [
            ManagedProcessSample(
                identity: renderer,
                cpuPercent: 3,
                gpuPercent: 19,
                isMainProcess: true
            )
        ].map { $0.scalingGPUShareToWatts(with: scale) }

        // An app with one process has no split to reason about, so the limiter
        // keeps it selected and lets the duty cycle decide when to pause it.
        let selection = ProcessLimitTargetSelector.select(
            samples: samples,
            limitPercent: 20,
            demand: .gpu
        )
        #expect(selection.controlledProcesses == [renderer])
        #expect(selection.controlledDemand == 19)
    }
}
