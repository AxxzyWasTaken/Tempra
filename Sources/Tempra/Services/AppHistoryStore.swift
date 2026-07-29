import Foundation

@MainActor
final class AppHistoryStore {
    private let persistence: AppPersistence
    private let activityRetention: TimeInterval = 7 * 24 * 60 * 60
    private let cpuHistoryRetention: TimeInterval = 24 * 60 * 60
    private let cpuHistorySampleInterval: TimeInterval = 15
    private let cpuHistoryPersistInterval: TimeInterval = 60
    private let maximumActivityCount = 200
    private var lastCPUHistorySampleDate: Date?
    private var lastCPUHistoryPersistDate: Date?

    private(set) var activityEvents: [ActivityEvent]
    private(set) var cpuHistorySamples: [CPUHistorySample]

    init(
        persistence: AppPersistence,
        activityEvents: [ActivityEvent],
        cpuHistorySamples: [CPUHistorySample],
        now: Date = Date()
    ) {
        self.persistence = persistence
        self.activityEvents = activityEvents
        self.cpuHistorySamples = cpuHistorySamples.sorted { $0.date < $1.date }
        trimActivity(now: now)
        trimCPUHistory(now: now)
        lastCPUHistorySampleDate = cpuHistorySamples.last?.date
    }

    func recordActivity(_ event: ActivityEvent, now: Date = Date()) throws -> [ActivityEvent] {
        let previousEvents = activityEvents
        activityEvents.insert(event, at: 0)
        trimActivity(now: now)
        do {
            try persistence.saveActivity(activityEvents)
        } catch {
            activityEvents = previousEvents
            throw error
        }
        return activityEvents
    }

    func recordCPUHistory(
        systemCPU: SystemCPUSnapshot,
        estimatedSavedSystemPercent: Double,
        interventionCount: Int,
        now: Date = Date()
    ) throws -> [CPUHistorySample]? {
        if let lastCPUHistorySampleDate,
           now.timeIntervalSince(lastCPUHistorySampleDate) < cpuHistorySampleInterval {
            return nil
        }

        let sample = CPUHistorySample(
            date: now,
            systemCPUPercent: systemCPU.totalPercent,
            performanceCPUPercent: systemCPU.performancePercent,
            efficiencyCPUPercent: systemCPU.efficiencyPercent,
            estimatedSavedCPUPercent: estimatedSavedSystemPercent,
            cpuTemperatureCelsius: systemCPU.cpuTemperatureCelsius,
            thermalPressure: systemCPU.thermalPressure,
            interventionCount: interventionCount
        )
        let shouldPersist = lastCPUHistoryPersistDate.map {
            now.timeIntervalSince($0) >= cpuHistoryPersistInterval
        } ?? true

        if shouldPersist {
            let previousSamples = cpuHistorySamples
            let previousSampleDate = lastCPUHistorySampleDate
            acceptCPUHistorySample(sample, now: now)
            do {
                try persistence.saveCPUHistory(cpuHistorySamples)
                lastCPUHistoryPersistDate = now
            } catch {
                cpuHistorySamples = previousSamples
                lastCPUHistorySampleDate = previousSampleDate
                throw error
            }
        } else {
            acceptCPUHistorySample(sample, now: now)
        }
        return cpuHistorySamples
    }

    func persistCPUHistory() throws {
        try persistence.saveCPUHistory(cpuHistorySamples)
    }

    private func trimActivity(now: Date) {
        let cutoff = now.addingTimeInterval(-activityRetention)
        activityEvents = Array(
            activityEvents
                .filter { $0.date >= cutoff }
                .sorted { $0.date > $1.date }
                .prefix(maximumActivityCount)
        )
    }

    private func trimCPUHistory(now: Date) {
        let cutoff = now.addingTimeInterval(-cpuHistoryRetention)
        let expiredCount = insertionIndex(for: cutoff)
        if expiredCount > 0 {
            cpuHistorySamples.removeFirst(expiredCount)
        }
    }

    private func acceptCPUHistorySample(_ sample: CPUHistorySample, now: Date) {
        if cpuHistorySamples.last.map({ $0.date <= sample.date }) ?? true {
            cpuHistorySamples.append(sample)
        } else {
            cpuHistorySamples.insert(sample, at: insertionIndex(for: sample.date))
        }
        lastCPUHistorySampleDate = sample.date
        trimCPUHistory(now: now)
    }

    private func insertionIndex(for date: Date) -> Int {
        var lowerBound = 0
        var upperBound = cpuHistorySamples.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if cpuHistorySamples[midpoint].date < date {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }
}
