import Foundation

struct HighCPUDetectionResult: Equatable {
    let attentionIdentifiers: Set<String>
    let notificationCandidates: [HighCPUAlert]
    let sustainedProcessIdentities: Set<ProcessIdentity>
}

struct HighCPUDetector {
    private struct Tracker {
        let bundleIdentifier: String
        var threshold: Double
        var aboveThresholdSince: Date? = nil
        var lastMeasuredAt: Date? = nil
        var backgroundSince: Date? = nil
        var recoveryStartedAt: Date? = nil
        var isAttention = false
        var lastNotifiedAt: Date? = nil
        var mutedUntil: Date? = nil
    }

    static let backgroundGrace: TimeInterval = 15
    static let launchGrace: TimeInterval = 60
    static let maximumSampleGap: TimeInterval = 12
    static let attentionRecoveryInterval: TimeInterval = 10
    static let minimumNotificationInterval: TimeInterval = 30

    private var trackers: [ProcessIdentity: Tracker] = [:]

    mutating func reset() {
        trackers.removeAll()
    }

    mutating func mute(
        processIdentity: ProcessIdentity,
        for interval: TimeInterval,
        now: Date = Date()
    ) {
        guard interval.isFinite, interval > 0,
              var tracker = trackers[processIdentity] else { return }
        let proposedDeadline = now.addingTimeInterval(interval)
        tracker.mutedUntil = max(tracker.mutedUntil ?? .distantPast, proposedDeadline)
        trackers[processIdentity] = tracker
    }

    mutating func evaluate(
        apps: [ManagedApp],
        preferences: AppPreferences,
        managedIdentifiers: Set<String> = [],
        suspendedIdentifiers: Set<String>,
        isManagementActive: Bool = true,
        canControlPrivilegedProcesses: Bool = false,
        isDoNotDisturbEnabled: Bool = false,
        now: Date = Date()
    ) -> HighCPUDetectionResult {
        let trackedApps = apps.compactMap { app -> (ManagedApp, ProcessIdentity)? in
            guard !app.isSystemProcess,
                  !SoundSourceCompatibilityPolicy.isProtected(
                      bundleIdentifier: app.bundleIdentifier,
                      applicationURL: app.bundleURL
                  ),
                  let processIdentity = representativeIdentity(for: app) else {
                return nil
            }
            return (app, processIdentity)
        }
        let activeProcessIdentities = Set(trackedApps.map(\.1))
        var notificationCandidates: [HighCPUAlert] = []
        var sustainedProcessIdentities: Set<ProcessIdentity> = []

        for processIdentity in Array(trackers.keys)
            where !activeProcessIdentities.contains(processIdentity) {
            trackers.removeValue(forKey: processIdentity)
        }
        var attentionIdentifiers = Set(
            trackers.values.compactMap { $0.isAttention ? $0.bundleIdentifier : nil }
        )

        for (app, processIdentity) in trackedApps {
            let threshold = preferences.highCPUThreshold
            var tracker = trackers[processIdentity] ?? Tracker(
                bundleIdentifier: app.bundleIdentifier,
                threshold: threshold
            )

            if tracker.threshold != threshold {
                tracker.threshold = threshold
                tracker.aboveThresholdSince = nil
                tracker.recoveryStartedAt = nil
                tracker.isAttention = false
                attentionIdentifiers.remove(app.bundleIdentifier)
            }

            if app.isFrontmost || app.isProtectedByForegroundOverlay {
                tracker.backgroundSince = nil
            } else {
                tracker.backgroundSince = tracker.backgroundSince ?? now
            }

            let hasFreshMeasurement = app.cpuPercent.isFinite
                && app.processSamples.contains(where: \.hasCPUMeasurement)
            if hasFreshMeasurement {
                if let lastMeasuredAt = tracker.lastMeasuredAt,
                   now < lastMeasuredAt
                    || now.timeIntervalSince(lastMeasuredAt) > Self.maximumSampleGap {
                    tracker.aboveThresholdSince = nil
                    tracker.recoveryStartedAt = nil
                    tracker.isAttention = false
                    attentionIdentifiers.remove(app.bundleIdentifier)
                }
                tracker.lastMeasuredAt = now

                if app.cpuPercent >= threshold {
                    tracker.aboveThresholdSince = tracker.aboveThresholdSince ?? now
                    tracker.recoveryStartedAt = nil
                } else {
                    tracker.aboveThresholdSince = nil
                    if tracker.isAttention {
                        tracker.recoveryStartedAt = tracker.recoveryStartedAt ?? now
                        if let recoveryStartedAt = tracker.recoveryStartedAt,
                           now.timeIntervalSince(recoveryStartedAt)
                               >= Self.attentionRecoveryInterval {
                            tracker.isAttention = false
                            tracker.recoveryStartedAt = nil
                            attentionIdentifiers.remove(app.bundleIdentifier)
                        }
                    }
                }
            }

            let isSustained = tracker.aboveThresholdSince.map {
                now.timeIntervalSince($0) > preferences.highCPUDuration
            } == true
            if isSustained {
                sustainedProcessIdentities.insert(processIdentity)
                if !tracker.isAttention {
                    tracker.isAttention = true
                    attentionIdentifiers.insert(app.bundleIdentifier)
                }
            }

            let canPresentAlert = tracker.lastNotifiedAt.map {
                now.timeIntervalSince($0) >= Self.minimumNotificationInterval
            } ?? true
            let isTemporarilyMuted = tracker.mutedUntil.map { $0 > now } == true
            if isSustained,
               preferences.highCPUAlertsEnabled,
               isManagementActive,
               isEligibleForNotification(
                   app,
                   processIdentity: processIdentity,
                   tracker: tracker,
                   duration: preferences.highCPUDuration,
                   managedIdentifiers: managedIdentifiers,
                   suspendedIdentifiers: suspendedIdentifiers,
                   canControlPrivilegedProcesses: canControlPrivilegedProcesses,
                   now: now
               ),
               !isDoNotDisturbEnabled,
               !isTemporarilyMuted,
               canPresentAlert,
               !preferences.ignoredHighCPUAlertBundleIdentifiers.contains(
                   app.bundleIdentifier
               ) {
                notificationCandidates.append(HighCPUAlert(
                    bundleIdentifier: app.bundleIdentifier,
                    displayName: app.name,
                    applicationURL: app.bundleURL,
                    processIdentity: processIdentity,
                    cpuPercent: app.cpuPercent,
                    threshold: threshold,
                    duration: preferences.highCPUDuration
                ))
                tracker.lastNotifiedAt = now
            }

            trackers[processIdentity] = tracker
        }

        notificationCandidates.sort {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            return $0.bundleIdentifier < $1.bundleIdentifier
        }
        return HighCPUDetectionResult(
            attentionIdentifiers: attentionIdentifiers,
            notificationCandidates: notificationCandidates,
            sustainedProcessIdentities: sustainedProcessIdentities
        )
    }

    private func representativeIdentity(for app: ManagedApp) -> ProcessIdentity? {
        let mainProcesses = app.processSamples.lazy.filter(\.isMainProcess)
        return (mainProcesses.min { $0.identity.pid < $1.identity.pid }
            ?? app.processSamples.min { $0.identity.pid < $1.identity.pid })?.identity
    }

    private func isEligibleForNotification(
        _ app: ManagedApp,
        processIdentity: ProcessIdentity,
        tracker: Tracker,
        duration: TimeInterval,
        managedIdentifiers: Set<String>,
        suspendedIdentifiers: Set<String>,
        canControlPrivilegedProcesses: Bool,
        now: Date
    ) -> Bool {
        guard !app.isFrontmost,
              !app.isProtectedByForegroundOverlay,
              !app.isBackgroundProcess,
              !isNestedHelperApplication(app),
              !managedIdentifiers.contains(app.bundleIdentifier),
              !suspendedIdentifiers.contains(app.bundleIdentifier),
              !processIdentity.requiresPrivilegedControl || canControlPrivilegedProcesses,
              app.processSamples.contains(where: \.hasCPUMeasurement),
              let backgroundSince = tracker.backgroundSince,
              now.timeIntervalSince(backgroundSince) > Self.backgroundGrace + duration else {
            return false
        }

        if app.isService {
            return true
        }

        let launchDate = app.launchedAt ?? Date(
            timeIntervalSince1970: Double(processIdentity.startTimeMicroseconds) / 1_000_000
        )
        let processAge = now.timeIntervalSince(launchDate)
        return processAge.isFinite && processAge > Self.launchGrace + duration
    }

    private func isNestedHelperApplication(_ app: ManagedApp) -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        return bundleURL.standardizedFileURL.pathComponents.dropLast().contains {
            $0.lowercased().hasSuffix(".app")
        }
    }
}

struct HighCPUAlertQueue {
    static let maximumCount = 32

    private(set) var alerts: [HighCPUAlert] = []

    var current: HighCPUAlert? { alerts.first }

    @discardableResult
    mutating func enqueue(_ candidates: [HighCPUAlert]) -> [HighCPUAlert] {
        var accepted: [HighCPUAlert] = []
        for candidate in candidates where alerts.count < Self.maximumCount {
            guard !alerts.contains(where: {
                $0.processIdentity == candidate.processIdentity
                    || $0.bundleIdentifier == candidate.bundleIdentifier
            }) else { continue }
            alerts.append(candidate)
            accepted.append(candidate)
        }
        return accepted
    }

    @discardableResult
    mutating func removeCurrent() -> HighCPUAlert? {
        guard !alerts.isEmpty else { return nil }
        return alerts.removeFirst()
    }

    mutating func removeAll() {
        alerts.removeAll(keepingCapacity: true)
    }

    mutating func removeAll(bundleIdentifier: String) {
        alerts.removeAll { $0.bundleIdentifier == bundleIdentifier }
    }

    mutating func removeResolvedQueuedAlerts(
        sustainedProcessIdentities: Set<ProcessIdentity>
    ) {
        guard alerts.count > 1 else { return }
        let resolvedIndices = alerts.indices.dropFirst().filter {
            !sustainedProcessIdentities.contains(alerts[$0].processIdentity)
        }
        for index in resolvedIndices.reversed() {
            alerts.remove(at: index)
        }
    }
}
