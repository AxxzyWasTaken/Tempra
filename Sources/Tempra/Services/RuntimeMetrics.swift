import Foundation

struct RuntimeMetrics {
    private let cpuAverageWindow: TimeInterval = 60
    private var cpuAverageSamples: [String: TimedAverage] = [:]

    var averageCPUByIdentifier: [String: Double] {
        cpuAverageSamples.mapValues(\.value)
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

}
