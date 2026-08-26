import Foundation

@MainActor
final class AppHistoryStore {
    private let persistence: AppPersistence
    private let activityRetention: TimeInterval = 7 * 24 * 60 * 60
    private let cpuHistoryRetention: TimeInterval = 24 * 60 * 60
    private let cpuHistorySampleInterval: TimeInterval = 15
    private let cpuHistoryPersistInterval: TimeInterval = 60
    private let appCPUHistorySampleInterval: TimeInterval = 30
    private let maximumTrackedAppsPerSample = 24
    private let maximumAppCPUHistoryCount = 75_000
    private let maximumActivityCount = 200
    private var lastCPUHistorySampleDate: Date?
    private var lastCPUHistoryPersistDate: Date?
    private var lastAppCPUHistorySampleDate: Date?
    private var lastAppCPUHistoryPersistDate: Date?

    private(set) var activityEvents: [ActivityEvent]
    private(set) var cpuHistorySamples: [CPUHistorySample]
    private(set) var appCPUHistorySamples: [AppCPUHistorySample]

    init(
        persistence: AppPersistence,
        activityEvents: [ActivityEvent],
        cpuHistorySamples: [CPUHistorySample],
        appCPUHistorySamples: [AppCPUHistorySample] = [],
        now: Date = Date()
    ) {
        self.persistence = persistence
        self.activityEvents = activityEvents
        self.cpuHistorySamples = cpuHistorySamples.sorted { $0.date < $1.date }
        self.appCPUHistorySamples = appCPUHistorySamples.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.bundleIdentifier < $1.bundleIdentifier
        }
        trimActivity(now: now)
        trimCPUHistory(now: now)
        trimAppCPUHistory(now: now)
        lastCPUHistorySampleDate = cpuHistorySamples.last?.date
        lastAppCPUHistorySampleDate = self.appCPUHistorySamples.last?.date
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
        estimatedSavedSystemPercent: Double?,
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
            estimatedSavedCPUPercent: estimatedSavedSystemPercent ?? 0,
            hasEstimatedSavedCPUMeasurement: estimatedSavedSystemPercent != nil,
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

    func recordAppCPUHistory(
        apps: [ManagedApp],
        estimatedSavedCPUByIdentifier: [String: Double],
        prioritizedBundleIdentifiers: Set<String>,
        focusedBundleIdentifier: String?,
        now: Date = Date()
    ) throws -> [AppCPUHistorySample]? {
        if let lastAppCPUHistorySampleDate {
            let elapsed = now.timeIntervalSince(lastAppCPUHistorySampleDate)
            guard elapsed >= appCPUHistorySampleInterval else { return nil }
        }

        let appsByIdentifier = Dictionary(
            apps.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var selectedIdentifiers: [String] = []
        var includedIdentifiers = Set<String>()
        func include(_ identifier: String) {
            guard selectedIdentifiers.count < maximumTrackedAppsPerSample,
                  appsByIdentifier[identifier] != nil,
                  includedIdentifiers.insert(identifier).inserted else {
                return
            }
            selectedIdentifiers.append(identifier)
        }

        if let focusedBundleIdentifier {
            include(focusedBundleIdentifier)
        }
        for identifier in prioritizedBundleIdentifiers.sorted() {
            include(identifier)
        }
        for app in apps.sorted(by: Self.appHistoryOrder) {
            include(app.bundleIdentifier)
        }

        let newSamples = selectedIdentifiers.compactMap { identifier -> AppCPUHistorySample? in
            guard let app = appsByIdentifier[identifier] else { return nil }
            let cpuPercent = app.cpuPercent.isFinite ? max(0, app.cpuPercent) : 0
            let estimatedSavedCPU = estimatedSavedCPUByIdentifier[identifier]
            let savedCPUPercent = estimatedSavedCPU?.isFinite == true
                ? max(0, estimatedSavedCPU ?? 0)
                : 0
            return AppCPUHistorySample(
                bundleIdentifier: identifier,
                date: now,
                cpuPercent: cpuPercent,
                estimatedSavedCPUPercent: savedCPUPercent
            )
        }
        guard !newSamples.isEmpty else {
            lastAppCPUHistorySampleDate = now
            return appCPUHistorySamples
        }

        let shouldPersist = lastAppCPUHistoryPersistDate.map {
            now.timeIntervalSince($0) >= cpuHistoryPersistInterval
        } ?? true
        let previousSamples = appCPUHistorySamples
        let previousSampleDate = lastAppCPUHistorySampleDate
        acceptAppCPUHistorySamples(newSamples, now: now)
        if shouldPersist {
            do {
                try persistence.saveAppCPUHistory(appCPUHistorySamples)
                lastAppCPUHistoryPersistDate = now
            } catch {
                appCPUHistorySamples = previousSamples
                lastAppCPUHistorySampleDate = previousSampleDate
                throw error
            }
        }
        return appCPUHistorySamples
    }

    func persistAppCPUHistory() throws {
        try persistence.saveAppCPUHistory(appCPUHistorySamples)
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

    private func trimAppCPUHistory(now: Date) {
        let cutoff = now.addingTimeInterval(-cpuHistoryRetention)
        if let firstRetainedIndex = appCPUHistorySamples.firstIndex(where: {
            $0.date >= cutoff
        }) {
            if firstRetainedIndex > 0 {
                appCPUHistorySamples.removeFirst(firstRetainedIndex)
            }
        } else {
            appCPUHistorySamples.removeAll(keepingCapacity: true)
        }
        if appCPUHistorySamples.count > maximumAppCPUHistoryCount {
            appCPUHistorySamples.removeFirst(
                appCPUHistorySamples.count - maximumAppCPUHistoryCount
            )
        }
    }

    private func acceptAppCPUHistorySamples(
        _ samples: [AppCPUHistorySample],
        now: Date
    ) {
        appCPUHistorySamples.append(contentsOf: samples)
        lastAppCPUHistorySampleDate = now
        trimAppCPUHistory(now: now)
    }

    private static func appHistoryOrder(_ lhs: ManagedApp, _ rhs: ManagedApp) -> Bool {
        if lhs.cpuPercent != rhs.cpuPercent {
            return lhs.cpuPercent > rhs.cpuPercent
        }
        return lhs.bundleIdentifier < rhs.bundleIdentifier
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
