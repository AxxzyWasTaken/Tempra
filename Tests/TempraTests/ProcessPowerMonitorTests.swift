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
    @Test("Management freezes the recent unmanaged energy intensity")
    func freezesEnergyIntensity() throws {
        var estimator = PowerSavingsEstimator()
        for energyIntensity in [2.0, 4.0, 6.0] {
            #expect(estimator.update(apps: [
                app(power: nil, energyIntensity: energyIntensity, status: .normal)
            ]).isEmpty)
        }

        var savings = estimator.update(
            apps: [app(power: 0.1, energyIntensity: 10, status: .limited(10))],
            savedCPUByIdentifier: ["example.app": 10]
        )
        #expect(abs(try #require(savings["example.app"]) - 0.4) < 0.000_000_1)

        savings = estimator.update(
            apps: [app(power: 0.5, energyIntensity: 10, status: .paused)],
            savedCPUByIdentifier: ["example.app": -10]
        )
        #expect(savings.isEmpty)

        savings = estimator.update(
            apps: [app(power: 0.2, energyIntensity: 10, status: .energyEfficient)],
            savedCPUByIdentifier: ["example.app": 5]
        )
        #expect(abs(try #require(savings["example.app"]) - 0.2) < 0.000_000_1)
    }

    @Test("Inactive states clear savings and resume baseline learning")
    func inactiveStates() throws {
        var estimator = PowerSavingsEstimator()
        #expect(estimator.update(apps: [
            app(power: 0.4, energyIntensity: 4, status: .normal)
        ]).isEmpty)
        #expect(estimator.update(apps: [
            app(power: 0.6, energyIntensity: 6, status: .waiting)
        ]).isEmpty)

        var savings = estimator.update(
            apps: [app(power: 0.1, energyIntensity: 1, status: .paused)],
            savedCPUByIdentifier: ["example.app": 10]
        )
        #expect(abs(try #require(savings["example.app"]) - 0.5) < 0.000_000_1)

        #expect(estimator.update(apps: [
            app(power: 0.8, energyIntensity: 8, status: .audioProtected)
        ]).isEmpty)
        savings = estimator.update(
            apps: [app(power: 0.2, energyIntensity: 1, status: .limited(20))],
            savedCPUByIdentifier: ["example.app": 20]
        )
        let expectedEnergyIntensity = (4.0 + 6.0 + 8.0) / 3
        #expect(
            abs(try #require(savings["example.app"]) - expectedEnergyIntensity * 0.2)
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
    func managedEnergyIntensity() throws {
        var estimator = PowerSavingsEstimator()
        #expect(estimator.update(
            apps: [app(power: nil, status: .limited(10))],
            savedCPUByIdentifier: ["example.app": 20]
        ).isEmpty)

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

@Suite("Battery power measurement")
struct BatteryPowerMeasurementTests {
    private final class ReadingSource: @unchecked Sendable {
        var reading: BatteryElectricalReading?
    }

    @Test("Battery voltage and current produce measured watts with smoothing")
    func batteryPowerAndSmoothing() throws {
        let source = ReadingSource()
        let monitor = BatteryPowerMonitor(readingProvider: { source.reading })

        source.reading = .discharging(
            voltageMillivolts: 12_000,
            amperageMilliamps: -1_000
        )
        #expect(monitor.sample() == .discharging(watts: 12))

        source.reading = .discharging(
            voltageMillivolts: 12_000,
            amperageMilliamps: -500
        )
        let smoothed = try #require(monitor.sample())
        #expect(smoothed == .discharging(watts: 9))

        source.reading = .externalPower
        #expect(monitor.sample() == .externalPower)

        source.reading = .discharging(
            voltageMillivolts: 12_000,
            amperageMilliamps: .min
        )
        #expect(monitor.sample() == nil)
    }

    @Test("Stable measurement windows freeze one completed comparison")
    func measuredComparison() throws {
        var tracker = BatteryPowerSavingsTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<10 {
            tracker.update(
                state: .discharging(watts: 12),
                activeLimitIdentifiers: [],
                now: start.addingTimeInterval(Double(offset))
            )
        }
        #expect(tracker.comparison.phase == .baselineReady)

        for offset in 10..<23 {
            tracker.update(
                state: .discharging(watts: 7),
                activeLimitIdentifiers: ["limited.app"],
                now: start.addingTimeInterval(Double(offset))
            )
        }

        #expect(tracker.comparison.phase == .complete)
        #expect(try #require(tracker.comparison.beforeLimitWatts) == 12)
        #expect(try #require(tracker.comparison.afterLimitWatts) == 7)
        #expect(try #require(tracker.comparison.savedWatts) == 5)

        tracker.update(
            state: .discharging(watts: 20),
            activeLimitIdentifiers: ["limited.app"],
            now: start.addingTimeInterval(23)
        )
        #expect(tracker.comparison.currentWatts == 20)
        #expect(tracker.comparison.afterLimitWatts == 7)
        #expect(tracker.comparison.savedWatts == 5)

        tracker.update(
            state: .externalPower,
            activeLimitIdentifiers: ["limited.app"],
            now: start.addingTimeInterval(24)
        )
        #expect(tracker.comparison == BatteryPowerComparison())
    }

    @Test("One extreme reading is removed from a stable baseline")
    func baselineOutlierRejection() throws {
        var tracker = BatteryPowerSavingsTracker()
        let start = Date(timeIntervalSince1970: 2_000)
        let readings: [Double] = [10, 10, 10, 40, 10, 10, 10, 10, 10, 10]
        for (offset, watts) in readings.enumerated() {
            tracker.update(
                state: .discharging(watts: watts),
                activeLimitIdentifiers: [],
                now: start.addingTimeInterval(Double(offset))
            )
        }

        #expect(tracker.comparison.phase == .baselineReady)
        #expect(try #require(tracker.comparison.beforeLimitWatts) == 10)
    }

    @Test("Unstable after readings produce no savings claim")
    func unstableAfterWindowIsInconclusive() {
        var tracker = BatteryPowerSavingsTracker()
        let start = Date(timeIntervalSince1970: 3_000)
        for offset in 0..<10 {
            tracker.update(
                state: .discharging(watts: 10),
                activeLimitIdentifiers: [],
                now: start.addingTimeInterval(Double(offset))
            )
        }
        for offset in 10..<23 {
            tracker.update(
                state: .discharging(watts: offset.isMultiple(of: 2) ? 2 : 20),
                activeLimitIdentifiers: ["limited.app"],
                now: start.addingTimeInterval(Double(offset))
            )
        }

        #expect(tracker.comparison.phase == .inconclusive)
        #expect(tracker.comparison.afterLimitWatts == nil)
        #expect(tracker.comparison.savedWatts == nil)
    }

    @Test("Changing the limited app set invalidates the comparison")
    func changedLimitSetIsInconclusive() {
        var tracker = BatteryPowerSavingsTracker()
        let start = Date(timeIntervalSince1970: 4_000)
        for offset in 0..<10 {
            tracker.update(
                state: .discharging(watts: 10),
                activeLimitIdentifiers: [],
                now: start.addingTimeInterval(Double(offset))
            )
        }
        tracker.update(
            state: .discharging(watts: 8),
            activeLimitIdentifiers: ["first.app"],
            now: start.addingTimeInterval(10)
        )
        tracker.update(
            state: .discharging(watts: 8),
            activeLimitIdentifiers: ["first.app", "second.app"],
            now: start.addingTimeInterval(11)
        )

        #expect(tracker.comparison.phase == .inconclusive)
        #expect(tracker.comparison.savedWatts == nil)
    }

    @Test("A long sample gap discards a stale baseline")
    func staleBaselineIsDiscarded() {
        var tracker = BatteryPowerSavingsTracker()
        let start = Date(timeIntervalSince1970: 5_000)
        for offset in 0..<10 {
            tracker.update(
                state: .discharging(watts: 10),
                activeLimitIdentifiers: [],
                now: start.addingTimeInterval(Double(offset))
            )
        }
        tracker.update(
            state: .discharging(watts: 10),
            activeLimitIdentifiers: [],
            now: start.addingTimeInterval(40)
        )

        #expect(tracker.comparison.phase == .collectingBaseline)
        #expect(tracker.comparison.beforeLimitWatts == nil)
    }

    @Test("Low-frequency sampling can complete without extra background work")
    func lowFrequencyMeasurementCompletes() {
        var tracker = BatteryPowerSavingsTracker()
        let start = Date(timeIntervalSince1970: 6_000)
        for offset in stride(from: 0, through: 25, by: 5) {
            tracker.update(
                state: .discharging(watts: 12),
                activeLimitIdentifiers: [],
                now: start.addingTimeInterval(Double(offset))
            )
        }
        for offset in stride(from: 30, through: 70, by: 5) {
            tracker.update(
                state: .discharging(watts: 8),
                activeLimitIdentifiers: ["limited.app"],
                now: start.addingTimeInterval(Double(offset))
            )
        }

        #expect(tracker.comparison.phase == .complete)
        #expect(tracker.comparison.savedWatts == 4)
    }

    @Test("Measurement phases use clear compact menu text")
    func measuredFormatting() {
        #expect(BatteryPowerFormatter.text(watts: 12.34) == "12.3 W")
        #expect(BatteryPowerFormatter.savingsText(watts: 2.25) == "2.2 W less")
        #expect(BatteryPowerFormatter.savingsText(watts: -1.25) == "1.2 W more")
        #expect(BatteryPowerFormatter.savingsText(watts: 0.01) == "No change")

        let collecting = BatteryPowerComparison(phase: .collectingBaseline)
        #expect(BatteryPowerFormatter.beforeLimitText(collecting) == "Measuring…")
        #expect(BatteryPowerFormatter.afterLimitText(collecting) == "Waiting")

        let measuringAfter = BatteryPowerComparison(
            beforeLimitWatts: 12,
            phase: .measuringAfter
        )
        #expect(BatteryPowerFormatter.beforeLimitText(measuringAfter) == "12.0 W")
        #expect(BatteryPowerFormatter.afterLimitText(measuringAfter) == "Measuring…")

        let complete = BatteryPowerComparison(
            beforeLimitWatts: 8,
            afterLimitWatts: 12,
            phase: .complete
        )
        #expect(BatteryPowerFormatter.changeText(complete) == "4.0 W more")

        let inconclusive = BatteryPowerComparison(phase: .inconclusive)
        #expect(BatteryPowerFormatter.changeText(inconclusive) == "Inconclusive")
    }
}
