import Foundation

enum AppPersistenceError: LocalizedError, Sendable {
    case invalidStoredType(name: String)
    case storedDataTooLarge(name: String)
    case decodingFailed(name: String, detail: String)
    case invalidValue(name: String, detail: String)
    case encodingFailed(name: String, detail: String)
    case writeFailed(name: String)

    var errorDescription: String? {
        switch self {
        case .invalidStoredType(let name):
            "The saved \(name) has an invalid storage type."
        case .storedDataTooLarge(let name):
            "The saved \(name) is too large to load safely."
        case .decodingFailed(let name, let detail):
            "Tempra could not decode the saved \(name): \(detail)"
        case .invalidValue(let name, let detail):
            "The saved \(name) contains an invalid value: \(detail)"
        case .encodingFailed(let name, let detail):
            "Tempra could not encode the \(name): \(detail)"
        case .writeFailed(let name):
            "Tempra could not verify that the \(name) was saved."
        }
    }
}

@MainActor
struct AppPersistence {
    let defaults: UserDefaults
    private let writer: (Any?, String) -> Void
    private static let maximumStoredBytes = 16 * 1_024 * 1_024

    init(
        defaults: UserDefaults = .standard,
        writer: ((Any?, String) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.writer = writer ?? { value, key in
            defaults.set(value, forKey: key)
        }
    }

    func loadEnabled() throws -> Bool {
        guard let stored = defaults.object(forKey: Keys.enabled) else { return true }
        guard let enabled = stored as? Bool else {
            throw AppPersistenceError.invalidStoredType(name: "management setting")
        }
        return enabled
    }

    func saveEnabled(_ enabled: Bool) throws {
        writer(enabled, Keys.enabled)
        guard defaults.object(forKey: Keys.enabled) as? Bool == enabled else {
            throw AppPersistenceError.writeFailed(name: "management setting")
        }
    }

    func loadRules() throws -> [String: AppRule] {
        guard let stored: [AppRule] = try decode(
            forKey: Keys.rules,
            name: "app rules"
        ) else { return [:] }
        try validateRules(stored)
        return Dictionary(uniqueKeysWithValues: stored.map { ($0.bundleIdentifier, $0) })
    }

    func saveRules(_ rules: [String: AppRule]) throws {
        let stored = rules.values.sorted { $0.displayName < $1.displayName }
        try validateRules(stored)
        try encode(
            stored,
            forKey: Keys.rules,
            name: "app rules"
        )
    }

    func loadPreferences() throws -> AppPreferences {
        guard let preferences: AppPreferences = try decode(
            forKey: Keys.preferences,
            name: "preferences"
        ) else { return AppPreferences() }
        try validatePreferences(preferences)
        return preferences
    }

    func savePreferences(_ preferences: AppPreferences) throws {
        try validatePreferences(preferences)
        try encode(preferences, forKey: Keys.preferences, name: "preferences")
    }

    func loadSuspensions() throws -> [String: RuleSuspension] {
        guard let stored: [RuleSuspension] = try decode(
            forKey: Keys.suspensions,
            name: "rule suspensions"
        ) else {
            return [:]
        }
        try validateSuspensions(stored)
        return Dictionary(uniqueKeysWithValues: stored.filter(\.isActive).map {
            ($0.bundleIdentifier, $0)
        })
    }

    func saveSuspensions(_ suspensions: [String: RuleSuspension]) throws {
        let stored = suspensions.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        try validateSuspensions(stored)
        try encode(
            stored,
            forKey: Keys.suspensions,
            name: "rule suspensions"
        )
    }

    func loadActivity() throws -> [ActivityEvent] {
        let events: [ActivityEvent] = try decode(
            forKey: Keys.activity,
            name: "activity history"
        ) ?? []
        try validateActivity(events)
        return events
    }

    func saveActivity(_ events: [ActivityEvent]) throws {
        try validateActivity(events)
        try encode(events, forKey: Keys.activity, name: "activity history")
    }

    func loadCPUHistory() throws -> [CPUHistorySample] {
        let samples: [CPUHistorySample] = try decode(
            forKey: Keys.cpuHistory,
            name: "CPU history"
        ) ?? []
        try validateCPUHistory(samples)
        return samples
    }

    func saveCPUHistory(_ samples: [CPUHistorySample]) throws {
        try validateCPUHistory(samples)
        try encode(samples, forKey: Keys.cpuHistory, name: "CPU history")
    }

    func loadAppCPUHistory() throws -> [AppCPUHistorySample] {
        let samples: [AppCPUHistorySample] = try decode(
            forKey: Keys.appCPUHistory,
            name: "app CPU history"
        ) ?? []
        try validateAppCPUHistory(samples)
        return samples
    }

    func saveAppCPUHistory(_ samples: [AppCPUHistorySample]) throws {
        try validateAppCPUHistory(samples)
        try encode(
            samples,
            forKey: Keys.appCPUHistory,
            name: "app CPU history"
        )
    }

    private func decode<Value: Decodable>(
        forKey key: String,
        name: String
    ) throws -> Value? {
        guard let stored = defaults.object(forKey: key) else { return nil }
        guard let data = stored as? Data else {
            throw AppPersistenceError.invalidStoredType(name: name)
        }
        guard data.count <= Self.maximumStoredBytes else {
            throw AppPersistenceError.storedDataTooLarge(name: name)
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw AppPersistenceError.decodingFailed(
                name: name,
                detail: error.localizedDescription
            )
        }
    }

    private func encode<Value: Encodable>(
        _ value: Value,
        forKey key: String,
        name: String
    ) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw AppPersistenceError.encodingFailed(
                name: name,
                detail: error.localizedDescription
            )
        }
        guard data.count <= Self.maximumStoredBytes else {
            throw AppPersistenceError.storedDataTooLarge(name: name)
        }
        writer(data, key)
        guard defaults.data(forKey: key) == data else {
            throw AppPersistenceError.writeFailed(name: name)
        }
    }

    private func validateRules(_ rules: [AppRule]) throws {
        guard rules.count <= 10_000 else {
            throw invalid("app rules", "there are more than 10,000 rules")
        }
        var identifiers = Set<String>()
        for rule in rules {
            try validateText(rule.bundleIdentifier, field: "bundle identifier", in: "app rules")
            try validateText(rule.displayName, field: "display name", in: "app rules")
            guard identifiers.insert(rule.bundleIdentifier).inserted else {
                throw invalid("app rules", "bundle identifier \(rule.bundleIdentifier) is duplicated")
            }
            try validateFinite(rule.limitPercent, field: "CPU limit", in: "app rules")
            try validateFinite(rule.delaySeconds, field: "delay", in: "app rules")
            guard CPULimitRange.allowed.contains(rule.limitPercent),
                  rule.delaySeconds >= 0,
                  rule.delaySeconds <= 5 * 60 else {
                throw invalid("app rules", "a CPU limit or delay is outside its allowed range")
            }
            try validateOptionalMinutes(rule.hideAfterMinutes, field: "hide delay")
            try validateOptionalMinutes(rule.quitAfterMinutes, field: "quit delay")
            guard rule.action != .pause || !rule.runOnEfficiencyCores else {
                throw invalid("app rules", "a paused rule cannot use power-saving core scheduling")
            }
        }
    }

    private func validatePreferences(_ preferences: AppPreferences) throws {
        try validateFinite(preferences.highCPUThreshold, field: "high CPU threshold", in: "preferences")
        try validateFinite(preferences.highCPUDuration, field: "high CPU duration", in: "preferences")
        try validateFinite(preferences.notificationCooldown, field: "notification cooldown", in: "preferences")
        guard preferences.highCPUThreshold >= 25,
              preferences.highCPUThreshold <= CPULimitRange.maximumPercent,
              preferences.highCPUDuration > 0,
              preferences.notificationCooldown > 0 else {
            throw invalid("preferences", "a CPU alert value is outside its allowed range")
        }
        guard preferences.profiles.count <= 1_000 else {
            throw invalid("preferences", "there are more than 1,000 profiles")
        }
        var profileIDs = Set<UUID>()
        for profile in preferences.profiles {
            try validateText(profile.name, field: "profile name", in: "preferences", limit: 60)
            guard profileIDs.insert(profile.id).inserted else {
                throw invalid("preferences", "profile identifier \(profile.id) is duplicated")
            }
            try validateFinite(profile.limitPercent, field: "profile CPU limit", in: "preferences")
            try validateFinite(profile.delaySeconds, field: "profile delay", in: "preferences")
            guard CPULimitRange.allowed.contains(profile.limitPercent),
                  profile.delaySeconds >= 0,
                  profile.delaySeconds <= 5 * 60 else {
                throw invalid("preferences", "a profile limit or delay is outside its allowed range")
            }
            if let idleAfterMinutes = profile.activation.idleAfterMinutes {
                try validateFinite(
                    idleAfterMinutes,
                    field: "profile idle duration",
                    in: "preferences"
                )
                guard (1...120).contains(idleAfterMinutes) else {
                    throw invalid(
                        "preferences",
                        "a profile idle duration is outside its allowed range"
                    )
                }
            }
        }
        guard preferences.ignoredHighCPUAlertBundleIdentifiers.count <= 10_000 else {
            throw invalid("preferences", "there are more than 10,000 ignored applications")
        }
        for identifier in preferences.ignoredHighCPUAlertBundleIdentifiers {
            try validateText(identifier, field: "ignored bundle identifier", in: "preferences")
        }
    }

    private func validateSuspensions(_ suspensions: [RuleSuspension]) throws {
        guard suspensions.count <= 10_000 else {
            throw invalid("rule suspensions", "there are more than 10,000 suspensions")
        }
        var identifiers = Set<String>()
        for suspension in suspensions {
            try validateText(
                suspension.bundleIdentifier,
                field: "bundle identifier",
                in: "rule suspensions"
            )
            guard identifiers.insert(suspension.bundleIdentifier).inserted else {
                throw invalid(
                    "rule suspensions",
                    "bundle identifier \(suspension.bundleIdentifier) is duplicated"
                )
            }
        }
    }

    private func validateActivity(_ events: [ActivityEvent]) throws {
        guard events.count <= 10_000 else {
            throw invalid("activity history", "there are more than 10,000 events")
        }
        var identifiers = Set<UUID>()
        for event in events {
            guard identifiers.insert(event.id).inserted else {
                throw invalid("activity history", "event identifier \(event.id) is duplicated")
            }
            try validateText(event.bundleIdentifier, field: "bundle identifier", in: "activity history")
            try validateText(event.displayName, field: "display name", in: "activity history")
            try validateText(event.detail, field: "event detail", in: "activity history", limit: 8_192)
        }
    }

    private func validateCPUHistory(_ samples: [CPUHistorySample]) throws {
        guard samples.count <= 100_000 else {
            throw invalid("CPU history", "there are more than 100,000 samples")
        }
        var dates = Set<Date>()
        for sample in samples {
            guard dates.insert(sample.date).inserted else {
                throw invalid("CPU history", "sample date \(sample.date) is duplicated")
            }
            let measurements = [
                sample.systemCPUPercent,
                sample.performanceCPUPercent,
                sample.efficiencyCPUPercent,
                sample.estimatedSavedCPUPercent
            ]
            guard measurements.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  sample.cpuTemperatureCelsius.map({ $0.isFinite }) ?? true,
                  sample.interventionCount >= 0 else {
                throw invalid("CPU history", "a sample contains a non-finite or negative value")
            }
        }
    }

    private func validateAppCPUHistory(_ samples: [AppCPUHistorySample]) throws {
        guard samples.count <= 75_000 else {
            throw invalid("app CPU history", "there are more than 75,000 samples")
        }
        var datesByIdentifier: [String: Set<Date>] = [:]
        for sample in samples {
            try validateText(
                sample.bundleIdentifier,
                field: "bundle identifier",
                in: "app CPU history"
            )
            guard datesByIdentifier[
                sample.bundleIdentifier,
                default: []
            ].insert(sample.date).inserted,
                  sample.cpuPercent.isFinite,
                  sample.cpuPercent >= 0,
                  sample.estimatedSavedCPUPercent.isFinite,
                  sample.estimatedSavedCPUPercent >= 0 else {
                throw invalid(
                    "app CPU history",
                    "a sample is duplicated or contains an invalid measurement"
                )
            }
        }
    }

    private func validateOptionalMinutes(_ value: Double?, field: String) throws {
        guard let value else { return }
        try validateFinite(value, field: field, in: "app rules")
        guard value >= 1, value <= 60 else {
            throw invalid("app rules", "\(field) must be between 1 and 60 minutes")
        }
    }

    private func validateFinite(_ value: Double, field: String, in name: String) throws {
        guard value.isFinite else {
            throw invalid(name, "\(field) is not a finite number")
        }
    }

    private func validateText(
        _ value: String,
        field: String,
        in name: String,
        limit: Int = 1_024
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value.count <= limit else {
            throw invalid(name, "\(field) is empty or too long")
        }
    }

    private func invalid(_ name: String, _ detail: String) -> AppPersistenceError {
        .invalidValue(name: name, detail: detail)
    }

    private enum Keys {
        static let rules = "temper.rules.v1"
        static let enabled = "temper.enabled"
        static let preferences = "temper.preferences.v1"
        static let suspensions = "temper.suspensions.v1"
        static let activity = "temper.activity.v1"
        static let cpuHistory = "temper.cpuHistory.v3"
        static let appCPUHistory = "temper.appCPUHistory.v1"
    }
}
