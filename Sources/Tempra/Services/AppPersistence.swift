import Foundation

@MainActor
struct AppPersistence {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadEnabled() -> Bool {
        defaults.object(forKey: Keys.enabled) as? Bool ?? true
    }

    func saveEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.enabled)
    }

    func loadRules() -> [String: AppRule] {
        guard let stored: [AppRule] = decode(forKey: Keys.rules) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.map { ($0.bundleIdentifier, $0) })
    }

    func saveRules(_ rules: [String: AppRule]) {
        encode(
            rules.values.sorted { $0.displayName < $1.displayName },
            forKey: Keys.rules
        )
    }

    func loadPreferences() -> AppPreferences {
        AppPreferencesStorage.load(from: defaults, key: Keys.preferences) ?? AppPreferences()
    }

    func savePreferences(_ preferences: AppPreferences) {
        AppPreferencesStorage.save(preferences, to: defaults, key: Keys.preferences)
    }

    func loadSuspensions() -> [String: RuleSuspension] {
        guard let stored: [RuleSuspension] = decode(forKey: Keys.suspensions) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: stored.filter(\.isActive).map {
            ($0.bundleIdentifier, $0)
        })
    }

    func saveSuspensions(_ suspensions: [String: RuleSuspension]) {
        encode(
            suspensions.values.sorted { $0.bundleIdentifier < $1.bundleIdentifier },
            forKey: Keys.suspensions
        )
    }

    func loadActivity() -> [ActivityEvent] {
        decode(forKey: Keys.activity) ?? []
    }

    func saveActivity(_ events: [ActivityEvent]) {
        encode(events, forKey: Keys.activity)
    }

    func loadCPUHistory() -> [CPUHistorySample] {
        decode(forKey: Keys.cpuHistory) ?? []
    }

    func saveCPUHistory(_ samples: [CPUHistorySample]) {
        encode(samples, forKey: Keys.cpuHistory)
    }

    private func decode<Value: Decodable>(forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private enum Keys {
        static let rules = "temper.rules.v1"
        static let enabled = "temper.enabled"
        static let preferences = "temper.preferences.v1"
        static let suspensions = "temper.suspensions.v1"
        static let activity = "temper.activity.v1"
        static let cpuHistory = "temper.cpuHistory.v3"
    }
}
