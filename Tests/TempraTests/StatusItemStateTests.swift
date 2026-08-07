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
        #expect(state.toolTip == "Tempra · CPU updates every 30 seconds")
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

    @Test("A CPU change does not replace or resize the status item")
    func cpuChangeOnlyUpdatesText() {
        var preferences = AppPreferences()
        preferences.showsCPUUsageInMenuBar = true

        let first = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 7),
            isEnabled: true,
            preferences: preferences
        )
        let second = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 100),
            isEnabled: true,
            preferences: preferences
        )
        let changes = StatusItemRenderChanges(previous: first, next: second)

        #expect(!changes.updatesImage)
        #expect(changes.updatesTitle)
        #expect(!changes.updatesToolTip)
        #expect(!changes.updatesLength)
        #expect(first.title.count == second.title.count)
    }

    @Test("A menu-bar display change updates the status item length")
    func cpuVisibilityChangeUpdatesLength() {
        var visiblePreferences = AppPreferences()
        visiblePreferences.showsCPUUsageInMenuBar = true
        var hiddenPreferences = visiblePreferences
        hiddenPreferences.showsCPUUsageInMenuBar = false

        let visible = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 42),
            isEnabled: true,
            preferences: visiblePreferences
        )
        let hidden = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 42),
            isEnabled: true,
            preferences: hiddenPreferences
        )
        let changes = StatusItemRenderChanges(previous: visible, next: hidden)

        #expect(changes.updatesTitle)
        #expect(changes.updatesToolTip)
        #expect(changes.updatesLength)
    }

    @Test("A management state change replaces the status item symbol")
    func managementStateChangeUpdatesImageAndLength() {
        let preferences = AppPreferences()
        let enabled = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 42),
            isEnabled: true,
            preferences: preferences
        )
        let disabled = StatusItemState(
            systemCPU: SystemCPUSnapshot(totalPercent: 42),
            isEnabled: false,
            preferences: preferences
        )
        let changes = StatusItemRenderChanges(previous: enabled, next: disabled)

        #expect(changes.updatesImage)
        #expect(changes.updatesToolTip)
        #expect(changes.updatesLength)
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
