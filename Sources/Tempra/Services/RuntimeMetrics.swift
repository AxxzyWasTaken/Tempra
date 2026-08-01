import Foundation

struct RuntimeMetrics {
    private let cpuAverageWindow: TimeInterval = 60
    private var cpuAverageSamples: [String: TimedAverage] = [:]
    private var powerSavingsEstimator = PowerSavingsEstimator()
    private var batteryPowerSavingsTracker = BatteryPowerSavingsTracker()
    private(set) var savedPowerByIdentifier: [String: Double] = [:]
    private(set) var isPowerSupported = false

    var batteryPowerComparison: BatteryPowerComparison {
        batteryPowerSavingsTracker.comparison
    }

    var averageCPUByIdentifier: [String: Double] {
        cpuAverageSamples.mapValues(\.value)
    }

    mutating func resetApplicationMetrics() {
        powerSavingsEstimator.reset()
        savedPowerByIdentifier.removeAll()
    }

    mutating func clearPowerMetrics() {
        powerSavingsEstimator.reset()
        savedPowerByIdentifier.removeAll()
    }

    mutating func setPowerSupported(_ isSupported: Bool) {
        isPowerSupported = isSupported
    }

    mutating func updateBatteryPower(
        state: BatteryPowerState?,
        activeLimitIdentifiers: Set<String>
    ) {
        batteryPowerSavingsTracker.update(
            state: state,
            activeLimitIdentifiers: activeLimitIdentifiers
        )
    }

    mutating func updateCPUAverages(apps: [ManagedApp], now: Date = Date()) {
        let runningIdentifiers = Set(apps.map(\.bundleIdentifier))
        cpuAverageSamples = cpuAverageSamples.filter { runningIdentifiers.contains($0.key) }
        for app in apps {
            var average = cpuAverageSamples[app.bundleIdentifier] ?? TimedAverage()
            average.add(app.cpuPercent, at: now, window: cpuAverageWindow)
            cpuAverageSamples[app.bundleIdentifier] = average
        }
    }

    mutating func updatePower(
        apps: [ManagedApp],
        samples: [String: ProcessPowerSample],
        statuses: [String: ManagementStatus],
        savedCPUByIdentifier: [String: Double]
    ) -> [ManagedApp] {
        let updatedApps = apps.map { app in
            var updated = app
            let sample = samples[app.bundleIdentifier]
            updated.cpuPowerWatts = sample?.watts
            updated.cpuEnergyJoulesPerCPUSecond = sample?.joulesPerCPUSecond
            if !app.isSystemProcess {
                updated.status = statuses[app.bundleIdentifier] ?? .normal
            }
            return updated
        }
        savedPowerByIdentifier = powerSavingsEstimator.update(
            apps: updatedApps.filter { !$0.isSystemProcess },
            savedCPUByIdentifier: savedCPUByIdentifier
        )
        return updatedApps
    }
}
