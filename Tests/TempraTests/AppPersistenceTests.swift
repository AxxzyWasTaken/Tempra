import Foundation
import Testing
@testable import Tempra

@Suite("App persistence")
@MainActor
struct AppPersistenceTests {
    @Test("Missing values use first-launch defaults")
    func missingValuesUseDefaults() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)

            let enabled = try persistence.loadEnabled()
            let rules = try persistence.loadRules()
            let preferences = try persistence.loadPreferences()
            let suspensions = try persistence.loadSuspensions()
            let activity = try persistence.loadActivity()
            let history = try persistence.loadCPUHistory()

            #expect(enabled)
            #expect(rules.isEmpty)
            #expect(preferences == AppPreferences())
            #expect(suspensions.isEmpty)
            #expect(activity.isEmpty)
            #expect(history.isEmpty)
        }
    }

    @Test("Administrator access onboarding is recorded after its first presentation")
    func privilegedAccessOnboardingPersists() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)
            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: MonitoringService(),
                launchAtLoginController: TestLaunchAtLoginController(),
                startsMonitoring: false,
                persistenceErrorHandler: { _ in }
            )

            #expect(store.shouldPresentPrivilegedAccessOnboarding)
            store.markPrivilegedAccessOnboardingPresented()

            #expect(!store.shouldPresentPrivilegedAccessOnboarding)
            #expect(try persistence.loadPreferences()
                .hasPresentedPrivilegedAccessOnboarding)
        }
    }

    @Test("Background and system process rules persist")
    func userOwnedBackgroundRulePersistence() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)
            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: MonitoringService(),
                launchAtLoginController: TestLaunchAtLoginController(),
                startsMonitoring: false,
                persistenceErrorHandler: { _ in }
            )
            let executablePath = "/Users/example/Library/Application Support/"
                + "CrossOver/Bottles/Game/wine64-preloader"
            let userIdentifier = BackgroundProcessPolicy.userOwnedIdentifier(
                command: executablePath,
                pid: 200
            )
            let systemIdentifier = BackgroundProcessPolicy.identifier(
                command: "/usr/libexec/logd",
                pid: 100
            )

            store.save(AppRule(
                bundleIdentifier: userIdentifier,
                displayName: "Game.exe",
                action: .limit,
                limitPercent: 50,
                applicationURL: URL(fileURLWithPath: executablePath)
            ))
            store.save(AppRule(
                bundleIdentifier: systemIdentifier,
                displayName: "logd",
                action: .limit,
                limitPercent: 50
            ))

            #expect(store.rules[userIdentifier]?.action == .limit)
            #expect(store.rules[systemIdentifier]?.action == .limit)
            #expect(try persistence.loadRules()[userIdentifier]?.limitPercent == 50)
            #expect(try persistence.loadRules()[systemIdentifier]?.limitPercent == 50)
        }
    }

    @Test("WindowServer CPU limits migrate to efficiency-only rules")
    func windowServerLimitMigration() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)
            let identifier = BackgroundProcessPolicy.identifier(
                command: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
                pid: 100
            )
            try persistence.saveRules([identifier: AppRule(
                bundleIdentifier: identifier,
                displayName: "WindowServer",
                action: .limit,
                limitPercent: 7
            )])

            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: MonitoringService(),
                launchAtLoginController: TestLaunchAtLoginController(),
                startsMonitoring: false,
                persistenceErrorHandler: { _ in }
            )

            let inMemoryRule = try #require(store.rules[identifier])
            let savedRule = try #require(persistence.loadRules()[identifier])
            #expect(inMemoryRule.action == .none)
            #expect(inMemoryRule.runOnEfficiencyCores)
            #expect(savedRule.action == .none)
            #expect(savedRule.runOnEfficiencyCores)

            var attemptedLimit = savedRule
            attemptedLimit.action = .limit
            attemptedLimit.limitPercent = 5
            store.save(attemptedLimit)
            #expect(store.rules[identifier]?.action == RuleAction.none)
            #expect(store.rules[identifier]?.runOnEfficiencyCores == true)
        }
    }

    @Test("CPU-limit rules preserve power-saving scheduling")
    func cpuLimitRulesPreservePowerSavingScheduling() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)
            let combinedRule = AppRule(
                bundleIdentifier: "example.game",
                displayName: "Example Game",
                action: .limit,
                runOnEfficiencyCores: true,
                limitPercent: 7
            )
            #expect(combinedRule.runOnEfficiencyCores)
            try persistence.saveRules([combinedRule.bundleIdentifier: combinedRule])

            let loadedRule = try #require(
                persistence.loadRules()[combinedRule.bundleIdentifier]
            )
            #expect(loadedRule.action == .limit)
            #expect(loadedRule.runOnEfficiencyCores)

            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: MonitoringService(),
                launchAtLoginController: TestLaunchAtLoginController(),
                startsMonitoring: false,
                persistenceErrorHandler: { _ in }
            )
            #expect(store.rules[combinedRule.bundleIdentifier]?.action == .limit)
            #expect(store.rules[combinedRule.bundleIdentifier]?.runOnEfficiencyCores == true)

            store.applyQuickRule(
                bundleIdentifier: combinedRule.bundleIdentifier,
                displayName: combinedRule.displayName,
                applicationURL: nil,
                action: .limit,
                limitPercent: 20,
                delaySeconds: 0
            )
            #expect(store.rules[combinedRule.bundleIdentifier]?.limitPercent == 20)
            #expect(store.rules[combinedRule.bundleIdentifier]?.runOnEfficiencyCores == true)

            store.setEfficiencyCoreScheduling(
                bundleIdentifier: combinedRule.bundleIdentifier,
                displayName: combinedRule.displayName,
                applicationURL: nil,
                enabled: false
            )
            #expect(store.rules[combinedRule.bundleIdentifier]?.action == .limit)
            #expect(store.rules[combinedRule.bundleIdentifier]?.runOnEfficiencyCores == false)

            store.setEfficiencyCoreScheduling(
                bundleIdentifier: combinedRule.bundleIdentifier,
                displayName: combinedRule.displayName,
                applicationURL: nil,
                enabled: true
            )

            #expect(store.rules[combinedRule.bundleIdentifier]?.action == .limit)
            #expect(store.rules[combinedRule.bundleIdentifier]?.runOnEfficiencyCores == true)
            #expect(
                try persistence.loadRules()[combinedRule.bundleIdentifier]?
                    .runOnEfficiencyCores == true
            )
        }
    }

    @Test("Saved SoundSource rules are removed and cannot be recreated")
    func soundSourceRuleMigration() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)
            let identifier = SoundSourceCompatibilityPolicy.primaryBundleIdentifier
            try persistence.saveRules([identifier: AppRule(
                bundleIdentifier: identifier,
                displayName: "SoundSource",
                action: .pause,
                hideAfterMinutes: 1,
                quitAfterMinutes: 2
            )])

            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: MonitoringService(),
                launchAtLoginController: TestLaunchAtLoginController(),
                startsMonitoring: false,
                persistenceErrorHandler: { _ in }
            )

            #expect(store.rules[identifier] == nil)
            #expect(try persistence.loadRules()[identifier] == nil)

            store.save(AppRule(
                bundleIdentifier: "com.rogueamoeba.FutureSoundSourceHost",
                displayName: "SoundSource Helper",
                action: .limit,
                limitPercent: 20,
                applicationURL: URL(
                    fileURLWithPath: "/Applications/SoundSource.app/Contents/XPCServices/"
                        + "FutureSoundSourceHost.xpc"
                )
            ))
            #expect(store.rules[identifier] == nil)
            #expect(try persistence.loadRules()[identifier] == nil)
            #expect(store.rules["com.rogueamoeba.FutureSoundSourceHost"] == nil)
            #expect(try persistence.loadRules()["com.rogueamoeba.FutureSoundSourceHost"] == nil)
        }
    }

    @Test("Menu-bar system samples record history without application data")
    func menuBarSamplesRecordLightweightHistory() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)
            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: MonitoringService(),
                launchAtLoginController: TestLaunchAtLoginController(),
                startsMonitoring: false,
                persistenceErrorHandler: { _ in }
            )
            let systemCPU = SystemCPUSnapshot(
                totalPercent: 24,
                performancePercent: 15,
                efficiencyPercent: 9,
                performanceCoreCount: 4,
                efficiencyCoreCount: 4,
                cpuTemperatureCelsius: nil,
                thermalPressure: .nominal
            )

            store.applyMonitoringSample(
                MonitoringSample(
                    generation: 1,
                    systemCPU: systemCPU,
                    apps: nil,
                    didRefreshApplications: false,
                    powerByIdentifier: [:],
                    powerMetricsSupported: true
                ),
                demand: .menuBar
            )

            let sample = try #require(store.cpuHistorySamples.last)
            #expect(sample.systemCPUPercent == 24)
            #expect(sample.performanceCPUPercent == 15)
            #expect(sample.efficiencyCPUPercent == 9)
            #expect(sample.estimatedSavedCPUPercent == 0)
            #expect(!sample.hasEstimatedSavedCPUMeasurement)
            #expect(sample.cpuTemperatureCelsius == nil)
            #expect(try persistence.loadCPUHistory() == store.cpuHistorySamples)
        }
    }

    @Test("Application-only samples preserve the battery measurement")
    func applicationOnlySamplesPreserveBatteryMeasurement() throws {
        try withDefaults { defaults in
            let store = try AppStore(
                persistence: AppPersistence(defaults: defaults),
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: MonitoringService(),
                launchAtLoginController: TestLaunchAtLoginController(),
                startsMonitoring: false,
                persistenceErrorHandler: { _ in }
            )
            let systemCPU = SystemCPUSnapshot(totalPercent: 10)

            store.applyMonitoringSample(
                MonitoringSample(
                    generation: 1,
                    systemCPU: systemCPU,
                    apps: nil,
                    didRefreshApplications: false,
                    powerByIdentifier: [:],
                    powerMetricsSupported: true,
                    batteryPower: .discharging(watts: 10)
                ),
                demand: .menuBar
            )
            #expect(store.batteryPowerComparison.currentWatts == 10)
            #expect(store.batteryPowerComparison.phase == .collectingBaseline)

            store.applyMonitoringSample(
                MonitoringSample(
                    generation: 1,
                    systemCPU: nil,
                    apps: nil,
                    didRefreshApplications: false,
                    powerByIdentifier: [:],
                    powerMetricsSupported: true
                ),
                demand: .dormant
            )
            #expect(store.batteryPowerComparison.currentWatts == 10)
            #expect(store.batteryPowerComparison.phase == .collectingBaseline)

            store.applyMonitoringSample(
                MonitoringSample(
                    generation: 1,
                    systemCPU: systemCPU,
                    apps: nil,
                    didRefreshApplications: false,
                    powerByIdentifier: [:],
                    powerMetricsSupported: true
                ),
                demand: .menuBar
            )
            #expect(store.batteryPowerComparison == BatteryPowerComparison())
        }
    }

    @Test("Corrupt rules stop startup without changing the original bytes")
    func corruptRulesArePreserved() throws {
        try withDefaults { defaults in
            let original = Data("not valid JSON".utf8)
            defaults.set(original, forKey: "temper.rules.v1")
            let persistence = AppPersistence(defaults: defaults)

            #expect(throws: AppPersistenceError.self) {
                _ = try AppStore(
                    persistence: persistence,
                    managementCoordinator: ProcessManagementCoordinator(),
                    monitoringService: MonitoringService(),
                    launchAtLoginController: TestLaunchAtLoginController(),
                    startsMonitoring: false,
                    persistenceErrorHandler: { _ in }
                )
            }
            #expect(defaults.data(forKey: "temper.rules.v1") == original)
        }
    }

    @Test("Valid startup does not rewrite saved rules")
    func validStartupDoesNotRewriteRules() throws {
        try withDefaults { defaults in
            let payload: [[String: Any]] = [[
                "bundleIdentifier": "example.app",
                "displayName": "Example",
                "action": "pause"
            ]]
            let original = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            defaults.set(original, forKey: "temper.rules.v1")

            _ = try AppStore(
                persistence: AppPersistence(defaults: defaults),
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: MonitoringService(),
                launchAtLoginController: TestLaunchAtLoginController(),
                startsMonitoring: false,
                persistenceErrorHandler: { _ in }
            )

            #expect(defaults.data(forKey: "temper.rules.v1") == original)
        }
    }

    @Test("Every corrupt JSON payload is reported and preserved")
    func corruptPayloadsArePreserved() throws {
        try withDefaults { defaults in
            typealias Loader = (AppPersistence) throws -> Void
            let loaders: [(key: String, load: Loader)] = [
                ("temper.preferences.v1", { _ = try $0.loadPreferences() }),
                ("temper.suspensions.v1", { _ = try $0.loadSuspensions() }),
                ("temper.activity.v1", { _ = try $0.loadActivity() }),
                ("temper.cpuHistory.v3", { _ = try $0.loadCPUHistory() })
            ]
            let original = Data("invalid JSON".utf8)

            for item in loaders {
                defaults.set(original, forKey: item.key)
                let persistence = AppPersistence(defaults: defaults)

                #expect(throws: AppPersistenceError.self) {
                    try item.load(persistence)
                }
                #expect(defaults.data(forKey: item.key) == original)
            }
        }
    }

    @Test("Decoded rules are validated before use")
    func invalidRulesAreRejected() throws {
        try withDefaults { defaults in
            let rules = [AppRule(
                bundleIdentifier: "example.app",
                displayName: "Example",
                action: .limit,
                limitPercent: -10
            )]
            let original = try JSONEncoder().encode(rules)
            defaults.set(original, forKey: "temper.rules.v1")
            let persistence = AppPersistence(defaults: defaults)

            #expect(throws: AppPersistenceError.self) {
                _ = try persistence.loadRules()
            }
            #expect(defaults.data(forKey: "temper.rules.v1") == original)
        }
    }

    @Test("Multi-core CPU limits survive persistence")
    func multiCoreLimitsRoundTrip() throws {
        try withDefaults { defaults in
            let limit = min(150, CPULimitRange.maximumPercent)
            #expect(limit > CPULimitRange.oneCorePercent)
            let rule = AppRule(
                bundleIdentifier: "example.app",
                displayName: "Example",
                action: .limit,
                limitPercent: limit
            )
            let persistence = AppPersistence(defaults: defaults)

            try persistence.saveRules([rule.bundleIdentifier: rule])
            let restored = try #require(persistence.loadRules()[rule.bundleIdentifier])

            #expect(restored.limitPercent == limit)
        }
    }

    @Test("Duplicate rule identifiers are rejected")
    func duplicateRulesAreRejected() throws {
        try withDefaults { defaults in
            let rules = [
                AppRule(bundleIdentifier: "example.app", displayName: "One", action: .pause),
                AppRule(bundleIdentifier: "example.app", displayName: "Two", action: .limit)
            ]
            defaults.set(try JSONEncoder().encode(rules), forKey: "temper.rules.v1")
            let persistence = AppPersistence(defaults: defaults)

            #expect(throws: AppPersistenceError.self) {
                _ = try persistence.loadRules()
            }
        }
    }

    @Test("Unknown rule actions do not become inactive rules")
    func unknownRuleActionsAreRejected() throws {
        try withDefaults { defaults in
            let payload: [[String: Any]] = [[
                "bundleIdentifier": "example.app",
                "displayName": "Example",
                "action": "unknown-action"
            ]]
            let original = try JSONSerialization.data(withJSONObject: payload)
            defaults.set(original, forKey: "temper.rules.v1")
            let persistence = AppPersistence(defaults: defaults)

            #expect(throws: AppPersistenceError.self) {
                _ = try persistence.loadRules()
            }
            #expect(defaults.data(forKey: "temper.rules.v1") == original)
        }
    }

    @Test("A failed replacement leaves the last saved rules unchanged")
    func failedSavePreservesRules() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)
            let validRule = AppRule(
                bundleIdentifier: "example.app",
                displayName: "Example",
                action: .limit,
                limitPercent: 50
            )
            try persistence.saveRules([validRule.bundleIdentifier: validRule])
            let original = try #require(defaults.data(forKey: "temper.rules.v1"))
            var invalidRule = validRule
            invalidRule.limitPercent = .infinity

            #expect(throws: AppPersistenceError.self) {
                try persistence.saveRules([invalidRule.bundleIdentifier: invalidRule])
            }
            #expect(defaults.data(forKey: "temper.rules.v1") == original)
        }
    }

    @Test("A verified write failure restores the last saved runtime value")
    func runtimeWriteFailureRollsBack() throws {
        try withDefaults { defaults in
            var reportedError: Error?
            let persistence = AppPersistence(defaults: defaults, writer: { _, _ in })
            let store = try AppStore(
                persistence: persistence,
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: MonitoringService(),
                launchAtLoginController: TestLaunchAtLoginController(),
                startsMonitoring: false,
                persistenceErrorHandler: { reportedError = $0 }
            )

            store.setEnabled(false)

            #expect(store.isEnabled)
            #expect(reportedError is AppPersistenceError)
            #expect(defaults.object(forKey: "temper.enabled") == nil)
        }
    }

    @Test("History write failures roll back the unsaved event")
    func historyWriteFailureRollsBack() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults, writer: { _, _ in })
            let history = AppHistoryStore(
                persistence: persistence,
                activityEvents: [],
                cpuHistorySamples: []
            )

            #expect(throws: AppPersistenceError.self) {
                _ = try history.recordActivity(ActivityEvent(
                    bundleIdentifier: "example.app",
                    displayName: "Example",
                    kind: .ruleSaved,
                    detail: "Rule saved."
                ))
            }
            #expect(history.activityEvents.isEmpty)
            #expect(defaults.object(forKey: "temper.activity.v1") == nil)
        }
    }

    @Test("Invalid management transitions do not replace saved history")
    func invalidManagementTransitionRollsBack() throws {
        try withDefaults { defaults in
            let ledger = try ManagementLedger(defaults: defaults)
            try ledger.persistLoadedState()
            let original = try #require(defaults.data(forKey: ManagementLedger.storageKey))

            #expect(throws: AppPersistenceError.self) {
                try ledger.transition(
                    bundleIdentifier: "",
                    displayName: "Example",
                    applicationURL: nil,
                    status: .paused
                )
            }
            #expect(defaults.data(forKey: ManagementLedger.storageKey) == original)
            #expect(ledger.durations(since: .distantPast).isEmpty)
        }
    }

    @Test("One limiting session does not persist each internal phase change")
    func limitPhaseChangesUseHeartbeatPersistence() throws {
        try withDefaults { defaults in
            let ledger = try ManagementLedger(defaults: defaults)
            let startedAt = Date(timeIntervalSince1970: 100)
            try ledger.transition(
                bundleIdentifier: "example.app",
                displayName: "Example",
                applicationURL: nil,
                status: .limited(10),
                at: startedAt
            )
            let initialData = try #require(
                defaults.data(forKey: ManagementLedger.storageKey)
            )

            try ledger.transition(
                bundleIdentifier: "example.app",
                displayName: "Example",
                applicationURL: nil,
                status: .energyEfficient,
                at: startedAt.addingTimeInterval(10)
            )

            #expect(defaults.data(forKey: ManagementLedger.storageKey) == initialData)
            #expect(ledger.durations(
                since: startedAt,
                now: startedAt.addingTimeInterval(20)
            ).first?.limitedDuration == 20)

            try ledger.transition(
                bundleIdentifier: "example.app",
                displayName: "Example",
                applicationURL: nil,
                status: .normal,
                at: startedAt.addingTimeInterval(20)
            )
            #expect(defaults.data(forKey: ManagementLedger.storageKey) != initialData)
        }
    }

    @Test("Corrupt management history is preserved")
    func corruptManagementHistoryIsPreserved() throws {
        try withDefaults { defaults in
            let original = Data("invalid management history".utf8)
            defaults.set(original, forKey: ManagementLedger.storageKey)

            #expect(throws: AppPersistenceError.self) {
                _ = try ManagementLedger(defaults: defaults)
            }
            #expect(defaults.data(forKey: ManagementLedger.storageKey) == original)
        }
    }

    private func withDefaults(
        _ operation: (UserDefaults) throws -> Void
    ) throws {
        let suiteName = "TempraPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try operation(defaults)
    }
}

@MainActor
private final class TestLaunchAtLoginController: LaunchAtLoginControlling {
    var isEnabled = false
    var requiresApproval = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}
