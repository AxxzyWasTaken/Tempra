import Foundation

enum ManagementMetricCategory: String, Codable, Equatable, Sendable {
    case limited
    case paused

    init?(status: ManagementStatus) {
        switch status {
        case .limited, .energyEfficient:
            self = .limited
        case .paused:
            self = .paused
        case .normal, .waiting, .audioProtected, .snoozed, .disabled, .notRunning,
                .unavailable:
            return nil
        }
    }
}

struct CompletedManagementInterval: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let bundleIdentifier: String
    var displayName: String
    var applicationURL: URL?
    let category: ManagementMetricCategory
    let startedAt: Date
    let endedAt: Date
}

struct ActiveManagementInterval: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let bundleIdentifier: String
    var displayName: String
    var applicationURL: URL?
    let category: ManagementMetricCategory
    let startedAt: Date
    var lastObservedAt: Date
    let sessionID: UUID
}

private struct ManagementLedgerState: Codable {
    var version = 1
    var completed: [CompletedManagementInterval] = []
    var active: [ActiveManagementInterval] = []
}

@MainActor
final class ManagementLedger {
    nonisolated static let storageKey = "temper.managementLedger.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    private let sessionID: UUID
    private let retention: TimeInterval
    private var state: ManagementLedgerState
    private var heartbeatTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = ManagementLedger.storageKey,
        sessionID: UUID = UUID(),
        now: Date = Date(),
        activityEvents: [ActivityEvent] = [],
        retention: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.sessionID = sessionID
        self.retention = retention

        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(ManagementLedgerState.self, from: data),
           stored.version == 1 {
            state = stored
            recoverPriorSessions(now: now)
        } else {
            state = Self.migrate(activityEvents: activityEvents)
        }
        trim(now: now)
        persist()
    }

    func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                heartbeat(at: Date())
            }
        }
    }

    func transition(
        bundleIdentifier: String,
        displayName: String,
        applicationURL: URL?,
        status: ManagementStatus,
        at date: Date = Date()
    ) {
        let category = ManagementMetricCategory(status: status)
        let activeIndex = state.active.firstIndex {
            $0.bundleIdentifier == bundleIdentifier
        }

        if let activeIndex {
            if state.active[activeIndex].category == category {
                state.active[activeIndex].displayName = displayName
                state.active[activeIndex].applicationURL = applicationURL
                state.active[activeIndex].lastObservedAt = max(
                    state.active[activeIndex].lastObservedAt,
                    date
                )
                persist()
                return
            }
            closeActive(at: activeIndex, endedAt: date)
        }

        if let category {
            state.active.append(ActiveManagementInterval(
                id: UUID(),
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                applicationURL: applicationURL,
                category: category,
                startedAt: date,
                lastObservedAt: date,
                sessionID: sessionID
            ))
        }
        trim(now: date)
        persist()
    }

    func heartbeat(at date: Date = Date()) {
        for index in state.active.indices where state.active[index].sessionID == sessionID {
            state.active[index].lastObservedAt = max(
                state.active[index].lastObservedAt,
                date
            )
        }
        trim(now: date)
        persist()
    }

    func shutdown(at date: Date = Date()) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for index in state.active.indices.reversed() {
            closeActive(at: index, endedAt: date)
        }
        trim(now: date)
        persist()
    }

    func durations(since startDate: Date, now: Date = Date()) -> [ManagementDurationSummary] {
        struct Totals {
            var displayName: String
            var applicationURL: URL?
            var limited: TimeInterval = 0
            var paused: TimeInterval = 0
        }

        var totals: [String: Totals] = [:]
        func accumulate(
            identifier: String,
            displayName: String,
            applicationURL: URL?,
            category: ManagementMetricCategory,
            startedAt: Date,
            endedAt: Date
        ) {
            let clippedStart = max(startDate, startedAt)
            let clippedEnd = min(now, endedAt)
            let duration = max(0, clippedEnd.timeIntervalSince(clippedStart))
            guard duration > 0 else { return }
            var total = totals[identifier] ?? Totals(
                displayName: displayName,
                applicationURL: applicationURL
            )
            total.displayName = displayName
            total.applicationURL = applicationURL ?? total.applicationURL
            switch category {
            case .limited:
                total.limited += duration
            case .paused:
                total.paused += duration
            }
            totals[identifier] = total
        }

        for interval in state.completed {
            accumulate(
                identifier: interval.bundleIdentifier,
                displayName: interval.displayName,
                applicationURL: interval.applicationURL,
                category: interval.category,
                startedAt: interval.startedAt,
                endedAt: interval.endedAt
            )
        }
        for interval in state.active {
            accumulate(
                identifier: interval.bundleIdentifier,
                displayName: interval.displayName,
                applicationURL: interval.applicationURL,
                category: interval.category,
                startedAt: interval.startedAt,
                endedAt: now
            )
        }

        return totals.map { identifier, total in
            ManagementDurationSummary(
                bundleIdentifier: identifier,
                displayName: total.displayName,
                applicationURL: total.applicationURL,
                limitedDuration: total.limited,
                pausedDuration: total.paused
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalDuration == rhs.totalDuration {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    == .orderedAscending
            }
            return lhs.totalDuration > rhs.totalDuration
        }
    }

    func interventionCount(since startDate: Date, now: Date = Date()) -> Int {
        state.completed.filter {
            $0.startedAt <= now && $0.endedAt >= startDate
        }.count + state.active.filter {
            $0.startedAt <= now && now >= startDate
        }.count
    }

    private func recoverPriorSessions(now: Date) {
        for index in state.active.indices.reversed() {
            guard state.active[index].sessionID != sessionID else { continue }
            closeActive(at: index, endedAt: min(now, state.active[index].lastObservedAt))
        }
    }

    private func closeActive(at index: Int, endedAt: Date) {
        let active = state.active.remove(at: index)
        guard endedAt > active.startedAt else { return }
        state.completed.append(CompletedManagementInterval(
            id: active.id,
            bundleIdentifier: active.bundleIdentifier,
            displayName: active.displayName,
            applicationURL: active.applicationURL,
            category: active.category,
            startedAt: active.startedAt,
            endedAt: endedAt
        ))
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        state.completed.removeAll { $0.endedAt < cutoff }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func migrate(activityEvents: [ActivityEvent]) -> ManagementLedgerState {
        var state = ManagementLedgerState()
        var active: [String: ActiveManagementInterval] = [:]

        for event in activityEvents.sorted(by: { $0.date < $1.date }) {
            let category: ManagementMetricCategory?
            switch event.kind {
            case .limited, .energyEfficient:
                category = .limited
            case .paused:
                category = .paused
            case .waiting, .restored, .audioProtected, .hidden, .quit, .snoozed,
                    .ruleDisabled, .ruleRemoved, .error:
                category = nil
            case .ruleSaved, .highCPU:
                continue
            }

            if let current = active[event.bundleIdentifier] {
                if current.category == category {
                    continue
                }
                if event.date > current.startedAt {
                    state.completed.append(CompletedManagementInterval(
                        id: current.id,
                        bundleIdentifier: current.bundleIdentifier,
                        displayName: current.displayName,
                        applicationURL: current.applicationURL,
                        category: current.category,
                        startedAt: current.startedAt,
                        endedAt: event.date
                    ))
                }
                active[event.bundleIdentifier] = nil
            }

            if let category {
                active[event.bundleIdentifier] = ActiveManagementInterval(
                    id: UUID(),
                    bundleIdentifier: event.bundleIdentifier,
                    displayName: event.displayName,
                    applicationURL: nil,
                    category: category,
                    startedAt: event.date,
                    lastObservedAt: event.date,
                    sessionID: UUID()
                )
            }
        }
        return state
    }
}
