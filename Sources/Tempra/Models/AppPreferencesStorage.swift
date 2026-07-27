import Foundation

enum AppPreferencesStorage {
    static func load(from defaults: UserDefaults, key: String) -> AppPreferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AppPreferences.self, from: data)
    }

    @discardableResult
    static func save(_ preferences: AppPreferences, to defaults: UserDefaults, key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(preferences) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
