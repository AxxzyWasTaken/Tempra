import Foundation
import Testing
@testable import Tempra

@Suite("App preferences")
struct AppPreferencesTests {
    @Test("Custom profiles, active selection, and appearance persist")
    func preferencesRoundTrip() throws {
        let suiteName = "TempraTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = ManagementProfile(
            id: UUID(),
            name: "Focused Work",
            limitPolicy: .maximum,
            limitPercent: 35,
            delayPolicy: .minimum,
            delaySeconds: 30
        )
        var preferences = AppPreferences()
        preferences.profiles = [profile]
        preferences.activeProfileID = profile.id
        preferences.appearance = .light
        preferences.includesEssentialSystemProcesses = true
        preferences.continuousMonitoringEnabled = true

        #expect(AppPreferencesStorage.save(preferences, to: defaults, key: "preferences"))
        let restored = try #require(
            AppPreferencesStorage.load(from: defaults, key: "preferences")
        )

        #expect(restored == preferences)
        #expect(restored.activeProfile == profile)
    }

    @Test("Continuous monitoring migrates to off")
    func continuousMonitoringDefaultsOff() throws {
        let data = try JSONSerialization.data(withJSONObject: [:])
        let restored = try JSONDecoder().decode(AppPreferences.self, from: data)

        #expect(!restored.continuousMonitoringEnabled)
    }

    @Test("Missing active profile IDs decode as no active profile")
    func missingActiveProfileFallsBackToNone() throws {
        let profile = ManagementProfile(name: "Quiet")
        let payload: [String: Any] = [
            "profiles": [
                [
                    "id": profile.id.uuidString,
                    "name": profile.name,
                    "limitPolicy": ProfileLimitPolicy.inherit.rawValue,
                    "limitPercent": 50,
                    "delayPolicy": ProfileDelayPolicy.inherit.rawValue,
                    "delaySeconds": 10
                ]
            ],
            "activeProfileID": UUID().uuidString
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let restored = try JSONDecoder().decode(AppPreferences.self, from: data)

        #expect(restored.profiles.count == 1)
        #expect(restored.activeProfileID == nil)
        #expect(restored.activeProfile == nil)
    }

    @Test("Profile policies adjust saved rules without replacing them")
    func profileAppliesPolicies() {
        let profile = ManagementProfile(
            name: "Battery",
            limitPolicy: .maximum,
            limitPercent: 25,
            delayPolicy: .minimum,
            delaySeconds: 30
        )
        let rule = AppRule(
            bundleIdentifier: "example.app",
            displayName: "Example",
            action: .limit,
            limitPercent: 60,
            delaySeconds: 10
        )

        let adjusted = profile.applying(to: rule)

        #expect(adjusted.limitPercent == 25)
        #expect(adjusted.delaySeconds == 30)
        #expect(rule.limitPercent == 60)
        #expect(rule.delaySeconds == 10)
    }
}
