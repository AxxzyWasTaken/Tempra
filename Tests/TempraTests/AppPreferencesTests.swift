import Foundation
import Testing
@testable import Tempra

@Suite("App preferences")
struct AppPreferencesTests {
    @Test("CPU limit range scales with logical cores")
    func cpuLimitRangeScalesWithLogicalCores() {
        #expect(CPULimitRange.maximumPercent(logicalCoreCount: 0) == 100)
        #expect(CPULimitRange.maximumPercent(logicalCoreCount: 1) == 100)
        #expect(CPULimitRange.maximumPercent(logicalCoreCount: 8) == 800)
        #expect(CPULimitRange.singleCore == 1...100)
    }

    @Test("CPU limits clamp to the authoritative range")
    func cpuLimitsUseAuthoritativeRange() {
        #expect(CPULimitRange.clamped(0) == CPULimitRange.allowed.lowerBound)
        #expect(CPULimitRange.clamped(.greatestFiniteMagnitude)
            == CPULimitRange.allowed.upperBound)
        #expect(CPULimitRange.clamped(50) == 50)
    }

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
            delaySeconds: 30,
            activation: ProfileActivation(
                powerCondition: .battery,
                idleAfterMinutes: 12
            )
        )
        var preferences = AppPreferences()
        preferences.profiles = [profile]
        preferences.activeProfileID = profile.id
        preferences.appearance = .light
        preferences.includesEssentialSystemProcesses = true
        preferences.continuousMonitoringEnabled = true
        preferences.hasPresentedPrivilegedAccessOnboarding = true
        preferences.managementPauseUntil = Date(timeIntervalSince1970: 10_000)

        try AppPreferencesStorage.save(preferences, to: defaults, key: "preferences")
        let loaded = try AppPreferencesStorage.load(from: defaults, key: "preferences")
        let restored = try #require(loaded)

        #expect(restored == preferences)
        #expect(restored.activeProfile == profile)
    }

    @Test("Preference encoding failures are reported")
    func preferenceEncodingFailureThrows() throws {
        let suiteName = "TempraTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = AppPreferences()
        preferences.highCPUThreshold = .infinity

        #expect(throws: AppPersistenceError.self) {
            try AppPreferencesStorage.save(preferences, to: defaults, key: "preferences")
        }
        #expect(defaults.object(forKey: "preferences") == nil)
    }

    @Test("Continuous monitoring migrates to off")
    func continuousMonitoringDefaultsOff() throws {
        let data = try JSONSerialization.data(withJSONObject: [:])
        let restored = try JSONDecoder().decode(AppPreferences.self, from: data)

        #expect(!restored.continuousMonitoringEnabled)
        #expect(!restored.hasPresentedPrivilegedAccessOnboarding)
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

    @Test("Duplicate profile identifiers are rejected")
    func duplicateProfilesFailDecoding() throws {
        let profileID = UUID()
        let profile: [String: Any] = [
            "id": profileID.uuidString,
            "name": "Quiet",
            "limitPolicy": ProfileLimitPolicy.inherit.rawValue,
            "limitPercent": 50,
            "delayPolicy": ProfileDelayPolicy.inherit.rawValue,
            "delaySeconds": 10
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "profiles": [profile, profile]
        ])

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AppPreferences.self, from: data)
        }
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
