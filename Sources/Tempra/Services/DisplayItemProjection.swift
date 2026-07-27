import AppKit
import Foundation

@MainActor
enum DisplayItemProjection {
    static func project(
        apps: [ManagedApp],
        rules: [String: AppRule],
        suspensions: [String: RuleSuspension],
        isEnabled: Bool,
        averageCPUByIdentifier: [String: Double],
        savedCPUByIdentifier: [String: Double],
        savedPowerByIdentifier: [String: Double],
        attentionIdentifiers: Set<String>
    ) -> [AppDisplayItem] {
        var items = apps.map { app in
            let rule = rules[app.bundleIdentifier]
            let status: ManagementStatus
            if let suspension = suspensions[app.bundleIdentifier], suspension.isActive {
                status = .snoozed(suspension.until)
            } else if let rule, !rule.isEnabled || !isEnabled {
                status = .disabled
            } else {
                status = app.status
            }

            return AppDisplayItem(
                bundleIdentifier: app.bundleIdentifier,
                name: app.name,
                applicationURL: app.bundleURL,
                cpuPercent: app.cpuPercent,
                averageCPUPercent: averageCPUByIdentifier[app.bundleIdentifier] ?? 0,
                estimatedSavedCPUPercent: savedCPUByIdentifier[app.bundleIdentifier] ?? 0,
                cpuPowerWatts: app.cpuPowerWatts,
                estimatedSavedPowerWatts: savedPowerByIdentifier[app.bundleIdentifier],
                isRunning: true,
                isFrontmost: app.isFrontmost,
                isHidden: app.isHidden,
                isPlayingAudio: app.isPlayingAudio,
                isSystemProcess: app.isSystemProcess,
                status: status,
                rule: rule,
                isAttention: attentionIdentifiers.contains(app.bundleIdentifier)
            )
        }
        let runningIdentifiers = Set(apps.map(\.bundleIdentifier))

        for rule in rules.values where !runningIdentifiers.contains(rule.bundleIdentifier) {
            let url = rule.applicationURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleIdentifier)
            items.append(AppDisplayItem(
                bundleIdentifier: rule.bundleIdentifier,
                name: rule.displayName,
                applicationURL: url,
                cpuPercent: 0,
                averageCPUPercent: 0,
                estimatedSavedCPUPercent: 0,
                isRunning: false,
                isFrontmost: false,
                isHidden: false,
                isPlayingAudio: false,
                status: .notRunning,
                rule: rule,
                isAttention: attentionIdentifiers.contains(rule.bundleIdentifier)
            ))
        }

        return items.sorted { lhs, rhs in
            if (lhs.rule != nil) != (rhs.rule != nil) {
                return lhs.rule != nil
            }
            if lhs.isRunning != rhs.isRunning {
                return lhs.isRunning
            }
            if lhs.cpuPercent == rhs.cpuPercent {
                return lhs.sortName < rhs.sortName
            }
            return lhs.cpuPercent > rhs.cpuPercent
        }
    }
}
