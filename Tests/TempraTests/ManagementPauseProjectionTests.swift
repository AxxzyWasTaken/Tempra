import Foundation
import Testing
@testable import Tempra

@Suite("Management pause projection")
@MainActor
struct ManagementPauseProjectionTests {
    @Test("A timed pause is visible on behavior rules")
    func behaviorRuleStatus() throws {
        let identifier = "example.app"
        let until = Date().addingTimeInterval(3_600)
        let app = ManagedApp(
            bundleIdentifier: identifier,
            name: "Example",
            bundleURL: nil,
            processIdentifiers: [],
            cpuPercent: 10,
            isFrontmost: false,
            isHidden: true,
            isPlayingAudio: false,
            isSystemProcess: false,
            status: .normal
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .pause
        )

        let item = try #require(DisplayItemProjection.project(
            apps: [app],
            rules: [identifier: rule],
            suspensions: [:],
            isEnabled: true,
            averageCPUByIdentifier: [:],
            savedCPUByIdentifier: [:],
            savedPowerByIdentifier: [:],
            managementPauseUntil: until,
            attentionIdentifiers: [],
            iconCache: AppIconCache()
        ).first)

        #expect(item.status == .managementPaused(until))
        #expect(!item.status.isActiveManagement)
    }
}
