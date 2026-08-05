import Foundation
import Testing
@testable import Tempra

@Suite("Management context")
struct ManagementContextTests {
    @Test("Profiles without activation data remain manual")
    func legacyProfileDecoding() throws {
        let id = UUID()
        let data = try #require(
            """
            {
              "id": "\(id.uuidString)",
              "name": "Legacy",
              "limitPolicy": "inherit",
              "limitPercent": 50,
              "delayPolicy": "inherit",
              "delaySeconds": 10
            }
            """.data(using: .utf8)
        )

        let profile = try JSONDecoder().decode(ManagementProfile.self, from: data)

        #expect(profile.activation == ProfileActivation())
        #expect(!profile.activation.isAutomatic)
    }

    @Test("The most specific matching automatic profile wins")
    func selectsMostSpecificProfile() {
        let battery = ManagementProfile(
            name: "Battery",
            activation: ProfileActivation(powerCondition: .battery)
        )
        let batteryAndIdle = ManagementProfile(
            name: "Battery and idle",
            activation: ProfileActivation(
                powerCondition: .battery,
                idleAfterMinutes: 10
            )
        )
        let externalPower = ManagementProfile(
            name: "External power",
            activation: ProfileActivation(powerCondition: .externalPower)
        )

        let selectedID = ManagementProfileSelector.automaticProfileID(
            profiles: [battery, batteryAndIdle, externalPower],
            context: ManagementContext(
                powerSource: .battery,
                userIdleDuration: 10 * 60
            )
        )

        #expect(selectedID == batteryAndIdle.id)
    }

    @Test("An unavailable context does not activate a profile")
    func unavailableContextKeepsManualSelection() {
        let profile = ManagementProfile(
            name: "Idle",
            activation: ProfileActivation(idleAfterMinutes: 5)
        )

        #expect(ManagementProfileSelector.automaticProfileID(
            profiles: [profile],
            context: .unavailable
        ) == nil)
    }

    @Test("Equal automatic conditions preserve profile order")
    func equalConditionsPreserveOrder() {
        let first = ManagementProfile(
            name: "First",
            activation: ProfileActivation(powerCondition: .battery)
        )
        let second = ManagementProfile(
            name: "Second",
            activation: ProfileActivation(powerCondition: .battery)
        )

        #expect(ManagementProfileSelector.automaticProfileID(
            profiles: [first, second],
            context: ManagementContext(powerSource: .battery, userIdleDuration: 0)
        ) == first.id)
    }
}
