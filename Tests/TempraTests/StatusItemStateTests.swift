import Foundation
import Testing
@testable import Tempra

@Suite("Status item state")
struct StatusItemStateTests {
    @Test("Disabled menu-bar CPU is icon-only")
    func dormantIsIconOnly() {
        var preferences = AppPreferences()
        preferences.showsCPUUsageInMenuBar = false
        preferences.continuousMonitoringEnabled = false

        let state = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 42),
            isEnabled: true,
            preferences: preferences
        )

        #expect(state.title.isEmpty)
        #expect(state.toolTip == "Tempra · Monitoring on demand")
    }

    @Test("Menu-bar CPU remains visible without continuous monitoring")
    func lightweightMenuBarCPU() {
        var preferences = AppPreferences()
        preferences.showsCPUUsageInMenuBar = true
        preferences.continuousMonitoringEnabled = false

        let state = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 42),
            isEnabled: true,
            preferences: preferences
        )

        #expect(state.title.hasSuffix("42%"))
        #expect(state.toolTip == "Tempra · 42% total CPU")
    }

    @Test("Continuous monitoring renders stable CPU text")
    func continuousCPUText() {
        var preferences = AppPreferences()
        preferences.showsCPUUsageInMenuBar = true
        preferences.continuousMonitoringEnabled = true

        let first = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 7.4),
            isEnabled: true,
            preferences: preferences
        )
        let equivalent = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 7.2),
            isEnabled: true,
            preferences: preferences
        )

        #expect(first.title.hasSuffix("7%"))
        #expect(first == equivalent)
    }

    @Test("A timed management pause is visible in the status item")
    func timedPauseStatus() {
        var preferences = AppPreferences()
        preferences.managementPauseUntil = Date().addingTimeInterval(60)

        let state = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 42),
            isEnabled: true,
            preferences: preferences
        )

        #expect(state.symbolName == "pause.circle")
        #expect(state.toolTip.contains("Paused until"))
    }
}
