import Foundation

@MainActor
extension AppStore {
    func rebuildDisplayItems() {
        guard isPresentationActive else { return }
        displayItems = DisplayItemProjection.project(
            apps: apps,
            rules: rules,
            suspensions: suspensions,
            isEnabled: isEnabled,
            averageCPUByIdentifier: runtimeMetrics.averageCPUByIdentifier,
            savedCPUByIdentifier: managementCoordinator.estimatedSavedCPUByIdentifier,
            activeCPULimitSessionIdentifiers: managementCoordinator
                .activeCPULimitSessionIdentifiers,
            protectionReasonsByIdentifier: managementCoordinator
                .protectionReasonsByIdentifier,
            managementPauseUntil: preferences.managementPauseUntil,
            attentionIdentifiers: attentionIdentifiers,
            iconCache: iconCache
        )
    }

    var activeManagementCount: Int {
        apps.filter { $0.status.isActiveManagement }.count
    }

    var totalCPUPercent: Double {
        apps.reduce(0) { $0 + $1.cpuPercent }
    }

    var managedCPUPercent: Double {
        apps.reduce(0) { result, app in
            guard let rule = rules[app.bundleIdentifier],
                  rule.isEnabled,
                  rule.hasBehavior else { return result }
            return result + app.cpuPercent
        }
    }

    var estimatedSavedCPUPercent: Double {
        managementCoordinator.estimatedSavedCPUByIdentifier.values.reduce(0, +)
    }

    var estimatedSavedSystemPercent: Double {
        estimatedSavedCPUPercent / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    var hasActivePowerManagement: Bool {
        apps.contains { $0.status.isActivelySavingPower }
    }

    var pausedCount: Int {
        apps.filter { $0.status == .paused }.count
    }

    var attentionCount: Int {
        attentionIdentifiers.count
    }

    func item(bundleIdentifier: String) -> AppDisplayItem? {
        displayItems.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func rule(for item: AppDisplayItem) -> AppRule {
        rules[item.bundleIdentifier] ?? AppRule(
            bundleIdentifier: item.bundleIdentifier,
            displayName: item.name,
            applicationURL: item.applicationURL
        )
    }

    func lastActivity(for bundleIdentifier: String) -> ActivityEvent? {
        activityEvents.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func appCPUHistory(for bundleIdentifier: String) -> [AppCPUHistorySample] {
        appCPUHistoryIndicesByIdentifier[bundleIdentifier, default: []].compactMap {
            appCPUHistorySamples.indices.contains($0)
                ? appCPUHistorySamples[$0]
                : nil
        }
    }

    func setHistoryFocus(bundleIdentifier: String?) {
        historyFocusBundleIdentifier = bundleIdentifier
    }

    func managementDurations(
        since startDate: Date,
        now: Date = Date()
    ) -> [ManagementDurationSummary] {
        managementLedger.durations(since: startDate, now: now)
    }

    func managementInterventionCount(since startDate: Date, now: Date = Date()) -> Int {
        managementLedger.interventionCount(since: startDate, now: now)
    }

    func suspensionUntil(for bundleIdentifier: String) -> Date? {
        guard let suspension = suspensions[bundleIdentifier], suspension.isActive else {
            return nil
        }
        return suspension.until
    }

    func profileName(from name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }
}
