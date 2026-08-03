import Foundation

struct HighCPUDetectionEvent: Equatable {
    let bundleIdentifier: String
    let cpuPercent: Double
}
struct HighCPUDetectionResult: Equatable {
    let attentionIdentifiers: Set<String>
    let pendingAlert: HighCPUAlert?
    let events: [HighCPUDetectionEvent]
}

struct HighCPUDetector {
    private struct Tracker {
        var exceededAt: Date?
        var recoveryStartedAt: Date?
        var isAttention = false
        var lastNotifiedAt: Date?
    }

    private var trackers: [String: Tracker] = [:]

    mutating func reset() {
        trackers.removeAll()
    }

    mutating func evaluate(
        apps: [ManagedApp],
        preferences: AppPreferences,
        suspendedIdentifiers: Set<String>,
        pendingAlert: HighCPUAlert?,
        now: Date = Date()
    ) -> HighCPUDetectionResult {
        let alertableApps = apps.filter {
            !$0.isSystemProcess
                && !SoundSourceCompatibilityPolicy.isProtected(
                    bundleIdentifier: $0.bundleIdentifier,
                    applicationURL: $0.bundleURL
                )
        }
        let activeIdentifiers = Set(alertableApps.map(\.bundleIdentifier))
        var attentionIdentifiers = Set(
            trackers.compactMap { $0.value.isAttention ? $0.key : nil }
        )
        var nextPendingAlert = pendingAlert
        var events: [HighCPUDetectionEvent] = []

        for identifier in Array(trackers.keys) where !activeIdentifiers.contains(identifier) {
            trackers.removeValue(forKey: identifier)
            attentionIdentifiers.remove(identifier)
            if nextPendingAlert?.bundleIdentifier == identifier {
                nextPendingAlert = nil
            }
        }

        for app in alertableApps {
            var tracker = trackers[app.bundleIdentifier] ?? Tracker()
            let threshold = preferences.highCPUThreshold

            if tracker.isAttention {
                if app.cpuPercent < threshold * 0.7 {
                    tracker.recoveryStartedAt = tracker.recoveryStartedAt ?? now
                    if let recoveryStartedAt = tracker.recoveryStartedAt,
                       now.timeIntervalSince(recoveryStartedAt) >= 10 {
                        tracker.isAttention = false
                        tracker.exceededAt = nil
                        tracker.recoveryStartedAt = nil
                        attentionIdentifiers.remove(app.bundleIdentifier)
                        if nextPendingAlert?.bundleIdentifier == app.bundleIdentifier {
                            nextPendingAlert = nil
                        }
                    }
                } else {
                    tracker.recoveryStartedAt = nil
                }
            } else if app.cpuPercent >= threshold {
                tracker.exceededAt = tracker.exceededAt ?? now
                if let exceededAt = tracker.exceededAt,
                   now.timeIntervalSince(exceededAt) >= preferences.highCPUDuration {
                    tracker.isAttention = true
                    attentionIdentifiers.insert(app.bundleIdentifier)
                    events.append(HighCPUDetectionEvent(
                        bundleIdentifier: app.bundleIdentifier,
                        cpuPercent: app.cpuPercent
                    ))
                }
            } else {
                tracker.exceededAt = nil
                tracker.recoveryStartedAt = nil
            }

            let canPresentAlert = tracker.lastNotifiedAt.map {
                now.timeIntervalSince($0) >= preferences.notificationCooldown
            } ?? true
            if tracker.isAttention,
               preferences.continuousMonitoringEnabled,
               preferences.highCPUAlertsEnabled,
               canPresentAlert,
               nextPendingAlert == nil,
               !preferences.ignoredHighCPUAlertBundleIdentifiers.contains(
                app.bundleIdentifier
               ),
               !suspendedIdentifiers.contains(app.bundleIdentifier) {
                nextPendingAlert = HighCPUAlert(
                    bundleIdentifier: app.bundleIdentifier,
                    displayName: app.name,
                    applicationURL: app.bundleURL,
                    cpuPercent: app.cpuPercent,
                    threshold: threshold,
                    duration: preferences.highCPUDuration
                )
                tracker.lastNotifiedAt = now
            }

            trackers[app.bundleIdentifier] = tracker
        }

        return HighCPUDetectionResult(
            attentionIdentifiers: attentionIdentifiers,
            pendingAlert: nextPendingAlert,
            events: events
        )
    }
}
