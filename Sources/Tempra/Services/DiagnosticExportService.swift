import AppKit
import Foundation
import UniformTypeIdentifiers

enum DiagnosticExportStatus: Equatable {
    case idle
    case exporting
    case saved(URL)
    case failed(String)
}

@MainActor
protocol DiagnosticExporting {
    func export(_ data: Data, suggestedFileName: String) throws -> URL?
}

@MainActor
struct NativeDiagnosticExporter: DiagnosticExporting {
    func export(_ data: Data, suggestedFileName: String) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Tempra Diagnostics"
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggestedFileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }
}

struct TempraDiagnosticReport: Codable, Equatable {
    struct AppInformation: Codable, Equatable {
        let version: String
        let operatingSystem: String
        let logicalProcessorCount: Int
    }

    struct ManagementInformation: Codable, Equatable {
        let isEnabled: Bool
        let managementPauseUntil: Date?
        let manualProfileID: UUID?
        let automaticProfileID: UUID?
        let effectiveProfileID: UUID?
        let privilegedControl: String
        let lifecycleRestorationFailureCount: Int
    }

    struct Rule: Codable, Equatable {
        let bundleIdentifier: String
        let displayName: String
        let action: String
        let lowersCPUPriority: Bool
        let limitPercent: Double
        let delaySeconds: TimeInterval
        let protectAudio: Bool
        let onlyWhenHidden: Bool
        let hideAfterMinutes: Double?
        let quitAfterMinutes: Double?
        let isEnabled: Bool
        let updatedAt: Date
    }

    struct Application: Codable, Equatable {
        struct Process: Codable, Equatable {
            let processIdentifier: Int32
            let startTimeMicroseconds: UInt64
            let requiresPrivilegedControl: Bool
            let cpuPercent: Double
            let isMainProcess: Bool
            let isPlayingAudio: Bool
            let networkActivity: String
            let protectionReasons: [String]
        }

        let bundleIdentifier: String
        let displayName: String
        let cpuPercent: Double
        let residentMemoryBytes: UInt64?
        let status: String
        let isFrontmost: Bool
        let isHidden: Bool
        let isPlayingAudio: Bool
        let processes: [Process]
    }

    struct SignalEvent: Codable, Equatable {
        struct StoppedDuration: Codable, Equatable {
            let processIdentifier: Int32
            let seconds: TimeInterval
        }

        let date: Date
        let bundleIdentifier: String?
        let operation: String
        let reason: String
        let requestedProcessIdentifiers: [Int32]
        let appliedProcessIdentifiers: [Int32]
        let staleProcessIdentifiers: [Int32]
        let failedProcessIdentifiers: [Int32]
        let stoppedDurations: [StoppedDuration]
    }

    struct LimitMeasurement: Codable, Equatable {
        let date: Date
        let bundleIdentifier: String
        let kind: String
        let requestedLimitPercent: Double?
        let measuredCPUPercent: Double?
        let cpuDeltaNanoseconds: UInt64?
        let wallDuration: TimeInterval?
        let deadlineLateness: TimeInterval?
        let activePulseCount: Int
        let serviceGap: TimeInterval?
    }

    let formatVersion: Int
    let generatedAt: Date
    let app: AppInformation
    let management: ManagementInformation
    let preferences: AppPreferences
    let rules: [Rule]
    let applications: [Application]
    let recentActivity: [ActivityEvent]
    let recentSignalEvents: [SignalEvent]
    let recentLimitMeasurements: [LimitMeasurement]

    static func build(
        generatedAt: Date,
        appVersion: String,
        isEnabled: Bool,
        preferences: AppPreferences,
        automaticProfileID: UUID?,
        effectiveProfileID: UUID?,
        privilegedControl: String,
        lifecycleRestorationFailure: ProcessRestorationResult?,
        rules: [String: AppRule],
        apps: [ManagedApp],
        statuses: [String: ManagementStatus],
        protectionReasonsByIdentifier:
            [String: [ProcessIdentity: Set<ProcessProtectionReason>]],
        activityEvents: [ActivityEvent],
        signalEvents: [ProcessControlSignalEvent],
        limitMeasurements: [ProcessLimitMeasurement]
    ) -> TempraDiagnosticReport {
        var reportPreferences = preferences
        reportPreferences.ignoredHighCPUAlertBundleIdentifiers = Set(
            preferences.ignoredHighCPUAlertBundleIdentifiers.map(
                diagnosticIdentifier
            )
        )
        let reportRules = rules.values.sorted {
            $0.bundleIdentifier < $1.bundleIdentifier
        }.map { rule in
            Rule(
                bundleIdentifier: diagnosticIdentifier(rule.bundleIdentifier),
                displayName: rule.displayName,
                action: rule.action.rawValue,
                lowersCPUPriority: rule.lowersCPUPriority,
                limitPercent: rule.limitPercent,
                delaySeconds: rule.delaySeconds,
                protectAudio: rule.protectAudio,
                onlyWhenHidden: rule.onlyWhenHidden,
                hideAfterMinutes: rule.hideAfterMinutes,
                quitAfterMinutes: rule.quitAfterMinutes,
                isEnabled: rule.isEnabled,
                updatedAt: rule.updatedAt
            )
        }

        let reportApplications = apps.sorted {
            $0.bundleIdentifier < $1.bundleIdentifier
        }.map { app in
            let processProtection = protectionReasonsByIdentifier[
                app.bundleIdentifier
            ] ?? [:]
            let rule = rules[app.bundleIdentifier]
            return Application(
                bundleIdentifier: diagnosticIdentifier(app.bundleIdentifier),
                displayName: app.name,
                cpuPercent: finite(app.cpuPercent),
                residentMemoryBytes: app.residentMemoryBytes,
                status: diagnosticStatus(
                    statuses[app.bundleIdentifier] ?? app.status
                ),
                isFrontmost: app.isFrontmost,
                isHidden: app.isHidden,
                isPlayingAudio: app.isPlayingAudio,
                processes: app.processSamples.map { sample in
                    var reasons = processProtection[sample.identity] ?? []
                    if rule?.protectAudio == true, sample.isPlayingAudio {
                        reasons.insert(.audioPlayback)
                    }
                    if sample.networkActivity.isLatencySensitive {
                        reasons.insert(.networkActivity)
                    }
                    if !sample.hasCPUMeasurement {
                        reasons.insert(.missingCPUMeasurement)
                    }
                    return Application.Process(
                        processIdentifier: sample.identity.pid,
                        startTimeMicroseconds: sample.identity.startTimeMicroseconds,
                        requiresPrivilegedControl: sample.identity
                            .requiresPrivilegedControl,
                        cpuPercent: finite(sample.cpuPercent),
                        isMainProcess: sample.isMainProcess,
                        isPlayingAudio: sample.isPlayingAudio,
                        networkActivity: diagnosticNetworkActivity(
                            sample.networkActivity
                        ),
                        protectionReasons: reasons
                            .map(\.rawValue)
                            .sorted()
                    )
                }
            )
        }

        let reportSignals = signalEvents.suffix(500).map { event in
            SignalEvent(
                date: event.date,
                bundleIdentifier: event.bundleIdentifier.map(diagnosticIdentifier),
                operation: event.operation.rawValue,
                reason: event.reason.rawValue,
                requestedProcessIdentifiers: event.requested.map(\.pid).sorted(),
                appliedProcessIdentifiers: event.result.applied.map(\.pid).sorted(),
                staleProcessIdentifiers: event.result.stale.map(\.pid).sorted(),
                failedProcessIdentifiers: event.result.failed.map(\.pid).sorted(),
                stoppedDurations: event.stoppedDurations.compactMap { identity, seconds in
                    guard seconds.isFinite, seconds >= 0 else { return nil }
                    return SignalEvent.StoppedDuration(
                        processIdentifier: identity.pid,
                        seconds: seconds
                    )
                }.sorted { $0.processIdentifier < $1.processIdentifier }
            )
        }

        let reportMeasurements = limitMeasurements.suffix(500).map { measurement in
            LimitMeasurement(
                date: measurement.date,
                bundleIdentifier: diagnosticIdentifier(
                    measurement.bundleIdentifier
                ),
                kind: measurement.kind.rawValue,
                requestedLimitPercent: finite(measurement.requestedLimitPercent),
                measuredCPUPercent: finite(measurement.measuredCPUPercent),
                cpuDeltaNanoseconds: measurement.cpuDeltaNanoseconds,
                wallDuration: finite(measurement.wallDuration),
                deadlineLateness: finite(measurement.deadlineLateness),
                activePulseCount: max(0, measurement.activePulseCount),
                serviceGap: finite(measurement.serviceGap)
            )
        }

        return TempraDiagnosticReport(
            formatVersion: 1,
            generatedAt: generatedAt,
            app: AppInformation(
                version: appVersion,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                logicalProcessorCount: max(1, ProcessInfo.processInfo.activeProcessorCount)
            ),
            management: ManagementInformation(
                isEnabled: isEnabled,
                managementPauseUntil: preferences.managementPauseUntil,
                manualProfileID: preferences.activeProfileID,
                automaticProfileID: automaticProfileID,
                effectiveProfileID: effectiveProfileID,
                privilegedControl: privilegedControl,
                lifecycleRestorationFailureCount: lifecycleRestorationFailure?
                    .failures.count ?? 0
            ),
            preferences: reportPreferences,
            rules: reportRules,
            applications: reportApplications,
            recentActivity: activityEvents.suffix(200).map { event in
                ActivityEvent(
                    id: event.id,
                    date: event.date,
                    bundleIdentifier: diagnosticIdentifier(
                        event.bundleIdentifier
                    ),
                    displayName: event.displayName,
                    kind: event.kind,
                    detail: event.detail
                )
            },
            recentSignalEvents: reportSignals,
            recentLimitMeasurements: reportMeasurements
        )
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func diagnosticNetworkActivity(
        _ activity: ProcessNetworkActivity
    ) -> String {
        switch activity {
        case .inactive: "inactive"
        case .active: "active"
        case .unknown: "unknown"
        }
    }

    private static func diagnosticIdentifier(_ identifier: String) -> String {
        guard let command = BackgroundProcessPolicy.command(from: identifier) else {
            return identifier
        }
        let name = BackgroundProcessPolicy.displayName(command: command, pid: 0)
        return "background-process:\(name)"
    }

    private static func diagnosticStatus(_ status: ManagementStatus) -> String {
        switch status {
        case .normal: "normal"
        case .waiting: "waiting"
        case .limited(let percent): "limited-\(Int(percent))"
        case .limitedWithProtectedProcesses(let percent):
            "best-effort-limited-\(Int(percent))"
        case .paused: "paused"
        case .lowerPriority: "lower-priority"
        case .audioProtected: "audio-protected"
        case .networkProtected: "network-protected"
        case .snoozed: "temporarily-resumed"
        case .managementPaused: "management-paused"
        case .disabled: "disabled"
        case .notRunning: "not-running"
        case .unavailable: "unavailable"
        }
    }
}
