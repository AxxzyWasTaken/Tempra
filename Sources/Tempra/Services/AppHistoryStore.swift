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

    init(persistence: AppPersistence, now: Date = Date()) {
        self.persistence = persistence
        activityEvents = persistence.loadActivity()
        cpuHistorySamples = persistence.loadCPUHistory()
        trimActivity(now: now)
        trimCPUHistory(now: now)
        lastCPUHistorySampleDate = cpuHistorySamples.last?.date
        persistence.saveActivity(activityEvents)
    }

    func recordActivity(_ event: ActivityEvent, now: Date = Date()) -> [ActivityEvent] {
        activityEvents.insert(event, at: 0)
        trimActivity(now: now)
        persistence.saveActivity(activityEvents)
        return activityEvents
    }

    func recordCPUHistory(
        systemCPU: SystemCPUSnapshot,
        estimatedSavedSystemPercent: Double,
        interventionCount: Int,
        now: Date = Date()
    ) -> [CPUHistorySample]? {
        if let lastCPUHistorySampleDate,
           now.timeIntervalSince(lastCPUHistorySampleDate) < cpuHistorySampleInterval {
            return nil
        }

        cpuHistorySamples.append(CPUHistorySample(
            date: now,
            systemCPUPercent: systemCPU.totalPercent,
            performanceCPUPercent: systemCPU.performancePercent,
            efficiencyCPUPercent: systemCPU.efficiencyPercent,
            estimatedSavedCPUPercent: estimatedSavedSystemPercent,
            cpuTemperatureCelsius: systemCPU.cpuTemperatureCelsius,
            thermalPressure: systemCPU.thermalPressure,
            interventionCount: interventionCount
        ))
        lastCPUHistorySampleDate = now
        trimCPUHistory(now: now)

        if lastCPUHistoryPersistDate.map({
            now.timeIntervalSince($0) >= cpuHistoryPersistInterval
        }) ?? true {
            persistence.saveCPUHistory(cpuHistorySamples)
            lastCPUHistoryPersistDate = now
        }
        return cpuHistorySamples
    }

    func persistCPUHistory() {
        persistence.saveCPUHistory(cpuHistorySamples)
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
        cpuHistorySamples = cpuHistorySamples
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
    }
}
