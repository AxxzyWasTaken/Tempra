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
