import Darwin
import Foundation

struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startTimeMicroseconds: UInt64
    let requiresPrivilegedControl: Bool

    init(
        pid: pid_t,
        startTimeMicroseconds: UInt64,
        requiresPrivilegedControl: Bool = false
    ) {
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
        self.requiresPrivilegedControl = requiresPrivilegedControl
    }
}

struct ManagedProcessSample: Equatable, Sendable {
    let identity: ProcessIdentity
    let cpuPercent: Double
    let isMainProcess: Bool
    let isPlayingAudio: Bool
    let networkActivity: ProcessNetworkActivity
    let hasCPUMeasurement: Bool

    init(
        identity: ProcessIdentity,
        cpuPercent: Double,
        isMainProcess: Bool,
        isPlayingAudio: Bool = false,
        networkActivity: ProcessNetworkActivity = .inactive,
        hasCPUMeasurement: Bool = true
    ) {
        self.identity = identity
        self.cpuPercent = cpuPercent.isFinite ? max(0, cpuPercent) : 0
        self.isMainProcess = isMainProcess
        self.isPlayingAudio = isPlayingAudio
        self.networkActivity = networkActivity
        self.hasCPUMeasurement = hasCPUMeasurement
    }
}

enum ProcessProtectionReason: String, CaseIterable, Hashable, Sendable {
    case audioPlayback
    case networkActivity
    case criticalFileActivity
    case missingCPUMeasurement
    case mainProcessLifeline

    var title: String {
        switch self {
        case .audioPlayback: "Playing audio"
        case .networkActivity: "Network responsiveness"
        case .criticalFileActivity: "Active download or file write"
        case .missingCPUMeasurement: "Waiting for a CPU measurement"
        case .mainProcessLifeline: "Main process responsiveness"
        }
    }

    var symbolName: String {
        switch self {
        case .audioPlayback: "speaker.wave.2.fill"
        case .networkActivity: "network"
        case .criticalFileActivity: "arrow.down.doc.fill"
        case .missingCPUMeasurement: "questionmark.circle"
        case .mainProcessLifeline: "app.badge.checkmark"
        }
    }
}

struct ProcessControlTarget: Sendable {
    let bundleIdentifier: String
    let processIdentities: Set<ProcessIdentity>
    let processSamples: [ManagedProcessSample]
    let usesApplicationCommands: Bool
    let launchedAt: Date?
    let cpuPercent: Double
    let isFrontmost: Bool
    let isHidden: Bool
    let isPlayingAudio: Bool
    var windowVisibility: AppWindowVisibility
    let isProtectedByForegroundOverlay: Bool
    let isProtectedAudioInfrastructure: Bool

    init(
        bundleIdentifier: String,
        processIdentities: Set<ProcessIdentity>,
        processSamples: [ManagedProcessSample]? = nil,
        usesApplicationCommands: Bool = true,
        launchedAt: Date? = nil,
        cpuPercent: Double,
        isFrontmost: Bool,
        isHidden: Bool,
        isPlayingAudio: Bool,
        windowVisibility: AppWindowVisibility = .unknown,
        isProtectedByForegroundOverlay: Bool = false,
        isProtectedAudioInfrastructure: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentities = processIdentities
        if let processSamples {
            self.processSamples = processSamples
                .filter { processIdentities.contains($0.identity) }
                .sorted { $0.identity.pid < $1.identity.pid }
        } else {
            let sortedIdentities = processIdentities.sorted { $0.pid < $1.pid }
            let sampleCPU = sortedIdentities.isEmpty
                ? 0
                : max(0, cpuPercent) / Double(sortedIdentities.count)
            self.processSamples = sortedIdentities.enumerated().map { index, identity in
                ManagedProcessSample(
                    identity: identity,
                    cpuPercent: sampleCPU,
                    isMainProcess: index == 0,
                    isPlayingAudio: isPlayingAudio
                )
            }
        }
        self.usesApplicationCommands = usesApplicationCommands
        self.launchedAt = launchedAt
        self.cpuPercent = cpuPercent
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.isPlayingAudio = isPlayingAudio
        self.windowVisibility = windowVisibility
        self.isProtectedByForegroundOverlay = isProtectedByForegroundOverlay
        self.isProtectedAudioInfrastructure = isProtectedAudioInfrastructure
    }
}

struct ProcessControlSnapshot: Sendable {
    let revision: UInt64
    let statuses: [String: ManagementStatus]
    let estimatedSavedCPUByIdentifier: [String: Double]
    let protectionReasonsByIdentifier:
        [String: [ProcessIdentity: Set<ProcessProtectionReason>]]
    let scheduledTickInterval: TimeInterval?
}

enum ProcessControllerEvent: Sendable {
    case statusTransition(
        revision: UInt64,
        bundleIdentifier: String,
        previous: ManagementStatus,
        current: ManagementStatus
    )
    case activity(revision: UInt64, bundleIdentifier: String, kind: ActivityKind, detail: String)
    case pauseWakeMonitoringChanged(revision: UInt64, enabled: Bool)
}
