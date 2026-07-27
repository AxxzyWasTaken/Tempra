import Foundation

enum AppPreferencesStorage {
    private static let maximumStoredBytes = 16 * 1_024 * 1_024

    static func load(from defaults: UserDefaults, key: String) throws -> AppPreferences? {
        guard let stored = defaults.object(forKey: key) else { return nil }
        guard let data = stored as? Data else {
            throw AppPersistenceError.invalidStoredType(name: "preferences")
        }
        guard data.count <= maximumStoredBytes else {
            throw AppPersistenceError.storedDataTooLarge(name: "preferences")
        }
        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data)
        } catch {
            throw AppPersistenceError.decodingFailed(
                name: "preferences",
                detail: error.localizedDescription
            )
        }
    }

    static func save(_ preferences: AppPreferences, to defaults: UserDefaults, key: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(preferences)
        } catch {
            throw AppPersistenceError.encodingFailed(
                name: "preferences",
                detail: error.localizedDescription
            )
        }
        guard data.count <= maximumStoredBytes else {
            throw AppPersistenceError.storedDataTooLarge(name: "preferences")
        }
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw AppPersistenceError.writeFailed(name: "preferences")
        }
    }
}
