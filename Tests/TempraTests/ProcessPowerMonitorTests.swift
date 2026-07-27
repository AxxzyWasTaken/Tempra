import Foundation
import Testing
@testable import Tempra

@Suite("Process power monitoring")
struct ProcessPowerMonitorTests {
    private final class CounterSource {
        var values: [pid_t: ProcessEnergyCounter] = [:]
        var readCount = 0

        func read(_ pid: pid_t) -> ProcessEnergyCounter? {
            readCount += 1
            return values[pid]
        }
    }

    @Test("Energy deltas aggregate helper processes and use a three-sample average")
    func aggregationAndRollingAverage() throws {
        let source = CounterSource()
        let monitor = ProcessPowerMonitor(isSupported: true, counterReader: source.read)
        let group = ProcessPowerGroup(identifier: "example.app", processIdentifiers: [1, 2])

        source.values = [
            1: counter(start: 10, energy: 100_000_000),
            2: counter(start: 20, energy: 200_000_000)
        ]
        #expect(monitor.sample(groups: [group], now: 1).isEmpty)

        source.values = [
            1: counter(start: 10, energy: 200_000_000),
            2: counter(start: 20, energy: 400_000_000)
        ]
        try expectPower(monitor.sample(groups: [group], now: 2), equals: 0.3)

        source.values = [
            1: counter(start: 10, energy: 400_000_000),
            2: counter(start: 20, energy: 800_000_000)
        ]
        try expectPower(monitor.sample(groups: [group], now: 3), equals: 0.45)

        source.values = [
            1: counter(start: 10, energy: 700_000_000),
            2: counter(start: 20, energy: 1_400_000_000)
        ]
        try expectPower(monitor.sample(groups: [group], now: 4), equals: 0.6)

        source.values = [
            1: counter(start: 10, energy: 1_100_000_000),
            2: counter(start: 20, energy: 2_200_000_000)
        ]
        try expectPower(monitor.sample(groups: [group], now: 5), equals: 0.9)
    }

    @Test("Energy intensity converts CPU time into joules per CPU second")
    func energyIntensity() throws {
        let source = CounterSource()
        let monitor = ProcessPowerMonitor(isSupported: true, counterReader: source.read)
        let group = ProcessPowerGroup(identifier: "example.app", processIdentifiers: [1, 2])

        source.values = [
            1: counter(start: 10, energy: 100_000_000, cpu: 10_000_000),
            2: counter(start: 20, energy: 200_000_000, cpu: 20_000_000)
        ]
        #expect(monitor.sample(groups: [group], now: 1).isEmpty)

        source.values = [
            1: counter(start: 10, energy: 200_000_000, cpu: 30_000_000),
            2: counter(start: 20, energy: 400_000_000, cpu: 50_000_000)
        ]
        let sample = try #require(monitor.sample(groups: [group], now: 2)["example.app"])
        #expect(abs(sample.watts - 0.3) < 0.000_000_1)
        #expect(abs(try #require(sample.joulesPerCPUSecond) - 6) < 0.000_000_1)
    }

    @Test("PID reuse and counter rollback never create spikes")
    func resetsAreIgnored() throws {
        let source = CounterSource()
        let monitor = ProcessPowerMonitor(isSupported: true, counterReader: source.read)
        let group = ProcessPowerGroup(identifier: "example.app", processIdentifiers: [7])

        source.values[7] = counter(start: 1, energy: 500_000_000)
        #expect(monitor.sample(groups: [group], now: 1).isEmpty)

        source.values[7] = counter(start: 2, energy: 100_000_000)
        #expect(monitor.sample(groups: [group], now: 2).isEmpty)

        source.values[7] = counter(start: 2, energy: 200_000_000)
        try expectPower(monitor.sample(groups: [group], now: 3), equals: 0.1)

        source.values[7] = counter(start: 2, energy: 50_000_000)
        #expect(monitor.sample(groups: [group], now: 4).isEmpty)

        source.values[7] = counter(start: 2, energy: 150_000_000)
        try expectPower(monitor.sample(groups: [group], now: 5), equals: 0.1)
    }

    @Test("Unavailable processes are ignored and unsupported systems do not read counters")
    func unavailableAndUnsupported() throws {
        let source = CounterSource()
        let group = ProcessPowerGroup(identifier: "example.app", processIdentifiers: [1, 2])
        let monitor = ProcessPowerMonitor(isSupported: true, counterReader: source.read)

        source.values[1] = counter(start: 1, energy: 100_000_000)
        #expect(monitor.sample(groups: [group], now: 1).isEmpty)
        source.values[1] = counter(start: 1, energy: 200_000_000)
        try expectPower(monitor.sample(groups: [group], now: 2), equals: 0.1)

        source.values.removeAll()
        #expect(monitor.sample(groups: [group], now: 3).isEmpty)

        let unsupported = ProcessPowerMonitor(isSupported: false, counterReader: source.read)
        let readsBefore = source.readCount
        #expect(unsupported.sample(groups: [group], now: 4).isEmpty)
        #expect(source.readCount == readsBefore)
    }

    @Test("Removing a group clears its counters and rolling samples")
    func processCleanup() {
        let source = CounterSource()
        let monitor = ProcessPowerMonitor(isSupported: true, counterReader: source.read)
        let group = ProcessPowerGroup(identifier: "example.app", processIdentifiers: [1])

        source.values[1] = counter(start: 1, energy: 100_000_000)
        #expect(monitor.sample(groups: [group], now: 1).isEmpty)
        source.values[1] = counter(start: 1, energy: 200_000_000)
        #expect(!monitor.sample(groups: [group], now: 2).isEmpty)

        #expect(monitor.sample(groups: [], now: 3).isEmpty)
        source.values[1] = counter(start: 1, energy: 400_000_000)
        #expect(monitor.sample(groups: [group], now: 4).isEmpty)
    }

    private func counter(
        start: UInt64,
        energy: UInt64,
        cpu: UInt64 = 0
    ) -> ProcessEnergyCounter {
        ProcessEnergyCounter(
            processStartTime: start,
            energyNanojoules: energy,
            cpuTimeNanoseconds: cpu
        )
    }

    private func expectPower(
        _ values: [String: ProcessPowerSample],
        equals expected: Double
    ) throws {
        let actual = try #require(values["example.app"]?.watts)
        #expect(abs(actual - expected) < 0.000_000_1)
    }
}

@Suite("Power savings estimates")
struct PowerSavingsEstimatorTests {
    @Test("Management freezes the recent unmanaged mean and clamps negative savings")
    func baselineAndClamp() throws {
        var estimator = PowerSavingsEstimator()
        for watts in [0.2, 0.4, 0.6] {
            #expect(estimator.update(apps: [app(power: watts, status: .normal)]).isEmpty)
        }

        var savings = estimator.update(apps: [app(power: 0.1, status: .limited(10))])
        #expect(abs(try #require(savings["example.app"]) - 0.3) < 0.000_000_1)

        savings = estimator.update(apps: [app(power: 0.5, status: .paused)])
        #expect(try #require(savings["example.app"]) == 0)

        savings = estimator.update(apps: [app(power: 0.2, status: .energyEfficient)])
        #expect(abs(try #require(savings["example.app"]) - 0.2) < 0.000_000_1)
    }

    @Test("Inactive states clear savings and resume baseline learning")
    func inactiveStates() throws {
        var estimator = PowerSavingsEstimator()
        #expect(estimator.update(apps: [app(power: 0.4, status: .normal)]).isEmpty)
        #expect(estimator.update(apps: [app(power: 0.6, status: .waiting)]).isEmpty)

        var savings = estimator.update(apps: [app(power: 0.1, status: .paused)])
        #expect(abs(try #require(savings["example.app"]) - 0.4) < 0.000_000_1)

        #expect(estimator.update(apps: [app(power: 0.8, status: .audioProtected)]).isEmpty)
        savings = estimator.update(apps: [app(power: 0.2, status: .limited(20))])
        let expectedBaseline = (0.4 + 0.6 + 0.8) / 3
        #expect(
            abs(try #require(savings["example.app"]) - (expectedBaseline - 0.2))
                < 0.000_000_1
        )
    }

    @Test("Missing baselines and exited apps do not invent savings")
    func missingBaselineAndCleanup() {
        var estimator = PowerSavingsEstimator()
        #expect(estimator.update(apps: [app(power: 0.1, status: .limited(10))]).isEmpty)

        #expect(estimator.update(apps: [app(power: 0.5, status: .normal)]).isEmpty)
        #expect(estimator.update(apps: []).isEmpty)
        #expect(estimator.update(apps: [app(power: 0.1, status: .paused)]).isEmpty)
    }

    @Test("Only limit, pause, and efficiency-core states count as active savings")
    func activeStatuses() {
        #expect(ManagementStatus.limited(10).isActivelySavingPower)
        #expect(ManagementStatus.paused.isActivelySavingPower)
        #expect(ManagementStatus.energyEfficient.isActivelySavingPower)
        #expect(!ManagementStatus.normal.isActivelySavingPower)
        #expect(!ManagementStatus.waiting.isActivelySavingPower)
        #expect(!ManagementStatus.audioProtected.isActivelySavingPower)
        #expect(!ManagementStatus.disabled.isActivelySavingPower)
    }

    @Test("Saved CPU uses the app’s learned energy intensity")
    func savedCPUUsesEnergyIntensity() throws {
        var estimator = PowerSavingsEstimator()
        #expect(estimator.update(apps: [
            app(power: 0.6, energyIntensity: 6, status: .normal)
        ]).isEmpty)

        let savings = estimator.update(
            apps: [app(power: 0.1, energyIntensity: 3, status: .limited(10))],
            savedCPUByIdentifier: ["example.app": 25]
        )
        #expect(abs(try #require(savings["example.app"]) - 1.5) < 0.000_000_1)
    }

    @Test("Managed samples provide an energy intensity when no baseline exists")
    func managedEnergyIntensityFallback() throws {
        var estimator = PowerSavingsEstimator()
        let savings = estimator.update(
            apps: [app(power: 0.1, energyIntensity: 4, status: .limited(10))],
            savedCPUByIdentifier: ["example.app": 20]
        )
        #expect(abs(try #require(savings["example.app"]) - 0.8) < 0.000_000_1)
    }

    private func app(
        power: Double?,
        energyIntensity: Double? = nil,
        status: ManagementStatus
    ) -> ManagedApp {
        ManagedApp(
            bundleIdentifier: "example.app",
            name: "Example",
            bundleURL: nil,
            processIdentifiers: [1],
            cpuPercent: 0,
            isFrontmost: false,
            isHidden: true,
            isPlayingAudio: false,
            isSystemProcess: false,
            cpuPowerWatts: power,
            cpuEnergyJoulesPerCPUSecond: energyIntensity,
            status: status
        )
    }
}

@Suite("Power metric presentation")
struct PowerMetricPresentationTests {
    @Test("Watt formatting handles unavailable, tiny, fractional, and estimated values")
    func formatting() {
        #expect(PowerMetricFormatter.text(watts: nil) == "—")
        #expect(PowerMetricFormatter.text(watts: 0) == "≈0 mW")
        #expect(PowerMetricFormatter.text(watts: 0.000_05) == "≈<0.1 mW")
        #expect(PowerMetricFormatter.text(watts: 0.000_2) == "≈0.2 mW")
        #expect(PowerMetricFormatter.text(watts: 0.002) == "≈2 mW")
        #expect(PowerMetricFormatter.text(watts: 0.42) == "≈420 mW")
        #expect(PowerMetricFormatter.text(watts: 1.24) == "≈1.2 W")
    }

    @Test("Summary aggregation distinguishes idle, unavailable, and missing estimates")
    func aggregation() throws {
        let normal = app(identifier: "normal", power: 0.1, status: .normal)
        let limited = app(identifier: "limited", power: 0.2, status: .limited(10))
        let paused = app(identifier: "paused", power: nil, status: .paused)
        let apps = [normal, limited, paused]

        #expect(
            abs(try #require(PowerMetricAggregation.trackedPower(
                apps: apps,
                isSupported: true
            )) - 0.3) < 0.000_000_1
        )
        #expect(PowerMetricAggregation.trackedPower(apps: apps, isSupported: false) == nil)
        #expect(PowerMetricAggregation.estimatedSavedPower(
            apps: [normal],
            savingsByIdentifier: [:],
            isSupported: true
        ) == 0)
        #expect(PowerMetricAggregation.estimatedSavedPower(
            apps: apps,
            savingsByIdentifier: [:],
            isSupported: true
        ) == nil)
        #expect(
            PowerMetricAggregation.estimatedSavedPower(
                apps: apps,
                savingsByIdentifier: ["limited": 0.08],
                isSupported: true
            ) == 0.08
        )
    }

    private func app(
        identifier: String,
        power: Double?,
        status: ManagementStatus
    ) -> ManagedApp {
        ManagedApp(
            bundleIdentifier: identifier,
            name: identifier,
            bundleURL: nil,
            processIdentifiers: [1],
            cpuPercent: 0,
            isFrontmost: false,
            isHidden: true,
            isPlayingAudio: false,
            isSystemProcess: false,
            cpuPowerWatts: power,
            status: status
        )
    }
}
