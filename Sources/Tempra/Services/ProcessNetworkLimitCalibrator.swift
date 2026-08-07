import Foundation

struct ProcessNetworkLimitCalibrationConfiguration: Equatable, Sendable {
    let baselineStopDuration: TimeInterval
    let maximumStopDuration: TimeInterval
    let validationDuration: TimeInterval
    let minimumHealthySamples: Int

    static let conservative = ProcessNetworkLimitCalibrationConfiguration(
        baselineStopDuration: 0.5,
        maximumStopDuration: 2,
        validationDuration: 20,
        minimumHealthySamples: 8
    )

    init(
        baselineStopDuration: TimeInterval,
        maximumStopDuration: TimeInterval,
        validationDuration: TimeInterval,
        minimumHealthySamples: Int
    ) {
        let baseline = baselineStopDuration.isFinite && baselineStopDuration > 0
            ? baselineStopDuration
            : 0.5
        self.baselineStopDuration = baseline
        self.maximumStopDuration = maximumStopDuration.isFinite
            ? max(baseline, maximumStopDuration)
            : baseline
        self.validationDuration = validationDuration.isFinite
            ? max(0.001, validationDuration)
            : 20
        self.minimumHealthySamples = max(1, minimumHealthySamples)
    }
}

struct ProcessNetworkLimitCalibrationUpdate: Equatable, Sendable {
    let stopDuration: TimeInterval
    let learnedStopDuration: TimeInterval?
    let detectedConnectionWarning: Bool
}

struct ProcessNetworkLimitCalibrator: Sendable {
    private struct Session: Sendable {
        let processIdentities: Set<ProcessIdentity>
        var currentStopDuration: TimeInterval
        var stableStopDuration: TimeInterval
        var previousStableStopDuration: TimeInterval
        var learnedStopDuration: TimeInterval?
        var anchorConnections: Set<ProcessNetworkConnectionID>
        var lastSampleAt: ContinuousClock.Instant
        var healthyDuration: TimeInterval
        var healthySampleCount: Int
        var isBlockedForSession: Bool
    }

    private let configuration: ProcessNetworkLimitCalibrationConfiguration
    private var sessions: [String: Session] = [:]

    init(
        configuration: ProcessNetworkLimitCalibrationConfiguration = .conservative
    ) {
        self.configuration = configuration
    }

    func stopDuration(
        for identifier: String,
        processIdentities: Set<ProcessIdentity>
    ) -> TimeInterval? {
        guard let session = sessions[identifier],
              session.processIdentities == processIdentities else {
            return nil
        }
        return session.currentStopDuration
    }

    mutating func reset(_ identifier: String) {
        sessions.removeValue(forKey: identifier)
    }

    mutating func resetAll() {
        sessions.removeAll(keepingCapacity: true)
    }

    mutating func update(
        identifier: String,
        processIdentities: Set<ProcessIdentity>,
        snapshot: ProcessNetworkConnectionSnapshot,
        learnedStopDuration: TimeInterval?,
        now: ContinuousClock.Instant
    ) -> ProcessNetworkLimitCalibrationUpdate {
        let baseline = configuration.baselineStopDuration
        guard !identifier.isEmpty, !processIdentities.isEmpty else {
            reset(identifier)
            return ProcessNetworkLimitCalibrationUpdate(
                stopDuration: baseline,
                learnedStopDuration: nil,
                detectedConnectionWarning: false
            )
        }

        let learnedDuration = normalizedLearnedDuration(learnedStopDuration)
        guard var session = sessions[identifier],
              session.processIdentities == processIdentities else {
            sessions[identifier] = Session(
                processIdentities: processIdentities,
                currentStopDuration: baseline,
                stableStopDuration: baseline,
                previousStableStopDuration: baseline,
                learnedStopDuration: learnedDuration,
                anchorConnections: snapshot.activeConnections,
                lastSampleAt: now,
                healthyDuration: 0,
                healthySampleCount: 0,
                isBlockedForSession: false
            )
            return ProcessNetworkLimitCalibrationUpdate(
                stopDuration: baseline,
                learnedStopDuration: nil,
                detectedConnectionWarning: false
            )
        }

        if session.anchorConnections.isEmpty {
            session.anchorConnections = snapshot.activeConnections
            session.lastSampleAt = now
            session.healthyDuration = 0
            session.healthySampleCount = 0
            sessions[identifier] = session
            return ProcessNetworkLimitCalibrationUpdate(
                stopDuration: session.currentStopDuration,
                learnedStopDuration: nil,
                detectedConnectionWarning: false
            )
        }

        let retainedConnections = session.anchorConnections.intersection(
            snapshot.activeConnections
        )
        let anchorFailed = !session.anchorConnections.isDisjoint(
            with: snapshot.failedConnections
        )
        guard snapshot.activity == .active,
              !retainedConnections.isEmpty,
              !anchorFailed else {
            return handleConnectionWarning(
                identifier: identifier,
                session: session,
                snapshot: snapshot,
                now: now
            )
        }

        session.anchorConnections = retainedConnections
        let elapsed = max(
            0,
            ProcessControlMath.timeInterval(session.lastSampleAt.duration(to: now))
        )
        let maximumCreditedGap = max(
            configuration.baselineStopDuration * 2,
            session.currentStopDuration * 2
        )
        session.healthyDuration += min(elapsed, maximumCreditedGap)
        session.healthySampleCount += 1
        session.lastSampleAt = now

        guard !session.isBlockedForSession,
              session.healthyDuration >= configuration.validationDuration,
              session.healthySampleCount >= configuration.minimumHealthySamples else {
            sessions[identifier] = session
            return ProcessNetworkLimitCalibrationUpdate(
                stopDuration: session.currentStopDuration,
                learnedStopDuration: nil,
                detectedConnectionWarning: false
            )
        }

        var durationToPersist: TimeInterval?
        if session.currentStopDuration > session.stableStopDuration {
            session.previousStableStopDuration = session.stableStopDuration
            session.stableStopDuration = session.currentStopDuration
            session.learnedStopDuration = session.currentStopDuration
            durationToPersist = session.currentStopDuration
        }

        let nextDuration = nextCandidateDuration(for: session)
        if nextDuration > session.currentStopDuration {
            session.currentStopDuration = nextDuration
            session.anchorConnections = snapshot.activeConnections
            session.healthyDuration = 0
            session.healthySampleCount = 0
            session.lastSampleAt = now
        }
        sessions[identifier] = session
        return ProcessNetworkLimitCalibrationUpdate(
            stopDuration: session.currentStopDuration,
            learnedStopDuration: durationToPersist,
            detectedConnectionWarning: false
        )
    }

    private func normalizedLearnedDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite else { return nil }
        return min(
            configuration.maximumStopDuration,
            max(configuration.baselineStopDuration, duration)
        )
    }

    private func nextCandidateDuration(for session: Session) -> TimeInterval {
        if session.currentStopDuration == configuration.baselineStopDuration,
           let learnedDuration = session.learnedStopDuration,
           learnedDuration > session.currentStopDuration {
            return learnedDuration
        }
        let grownDuration = max(
            session.currentStopDuration + 0.1,
            session.currentStopDuration * 1.5
        )
        return min(configuration.maximumStopDuration, grownDuration)
    }

    private mutating func handleConnectionWarning(
        identifier: String,
        session originalSession: Session,
        snapshot: ProcessNetworkConnectionSnapshot,
        now: ContinuousClock.Instant
    ) -> ProcessNetworkLimitCalibrationUpdate {
        var session = originalSession
        let rollbackDuration: TimeInterval
        if session.currentStopDuration > session.stableStopDuration {
            rollbackDuration = session.stableStopDuration
        } else {
            rollbackDuration = session.previousStableStopDuration
        }
        let normalizedRollback = max(
            configuration.baselineStopDuration,
            min(session.currentStopDuration, rollbackDuration)
        )
        let lowersLearnedDuration = session.learnedStopDuration.map {
            normalizedRollback < $0
        } ?? false

        session.currentStopDuration = normalizedRollback
        session.stableStopDuration = normalizedRollback
        session.previousStableStopDuration = configuration.baselineStopDuration
        session.learnedStopDuration = normalizedRollback
        session.anchorConnections = snapshot.activeConnections
        session.lastSampleAt = now
        session.healthyDuration = 0
        session.healthySampleCount = 0
        session.isBlockedForSession = true
        sessions[identifier] = session

        return ProcessNetworkLimitCalibrationUpdate(
            stopDuration: normalizedRollback,
            learnedStopDuration: lowersLearnedDuration ? normalizedRollback : nil,
            detectedConnectionWarning: true
        )
    }
}

protocol ProcessNetworkLimitCalibrationPersisting: Sendable {
    func learnedStopDuration(for key: String) -> TimeInterval?
    @discardableResult
    func saveLearnedStopDuration(_ duration: TimeInterval, for key: String) -> Bool
}

final class UserDefaultsProcessNetworkLimitCalibrationStore:
    ProcessNetworkLimitCalibrationPersisting, @unchecked Sendable {
    private struct StoredRecord: Codable {
        let stopDuration: TimeInterval
        let updatedAt: TimeInterval
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumRecordCount = 512
    private let maximumStoredBytes = 256 * 1_024

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "networkLimitCalibrations.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func learnedStopDuration(for key: String) -> TimeInterval? {
        guard Self.isValidKey(key) else { return nil }
        return withLock {
            guard let duration = loadRecords()[key]?.stopDuration,
                  duration.isFinite,
                  duration > 0 else {
                return nil
            }
            return duration
        }
    }

    @discardableResult
    func saveLearnedStopDuration(_ duration: TimeInterval, for key: String) -> Bool {
        guard Self.isValidKey(key), duration.isFinite, duration > 0 else { return false }
        return withLock {
            var records = loadRecords()
            records[key] = StoredRecord(
                stopDuration: duration,
                updatedAt: Date().timeIntervalSince1970
            )
            if records.count > maximumRecordCount {
                let keysToRemove = records
                    .sorted { first, second in first.value.updatedAt < second.value.updatedAt }
                    .prefix(records.count - maximumRecordCount)
                    .map(\.key)
                for oldKey in keysToRemove {
                    records.removeValue(forKey: oldKey)
                }
            }
            guard let data = try? JSONEncoder().encode(records),
                  data.count <= maximumStoredBytes else {
                return false
            }
            defaults.set(data, forKey: storageKey)
            return defaults.data(forKey: storageKey) == data
        }
    }

    private func loadRecords() -> [String: StoredRecord] {
        guard let data = defaults.data(forKey: storageKey),
              data.count <= maximumStoredBytes,
              let decoded = try? JSONDecoder().decode(
                [String: StoredRecord].self,
                from: data
              ),
              decoded.count <= maximumRecordCount else {
            return [:]
        }
        return decoded.filter { key, record in
            Self.isValidKey(key)
                && record.stopDuration.isFinite
                && record.stopDuration > 0
                && record.updatedAt.isFinite
        }
    }

    private static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 1_024
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
