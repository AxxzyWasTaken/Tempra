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

struct ProcessControlTarget: Sendable {
    let bundleIdentifier: String
    let processIdentities: Set<ProcessIdentity>
    let usesApplicationCommands: Bool
    let launchedAt: Date?
    let cpuPercent: Double
    let isFrontmost: Bool
    let isHidden: Bool
    let isPlayingAudio: Bool
    var windowVisibility: AppWindowVisibility
    let isProtectedByMenuBarOverlay: Bool
    let isProtectedAudioInfrastructure: Bool

    init(
        bundleIdentifier: String,
        processIdentities: Set<ProcessIdentity>,
        usesApplicationCommands: Bool = true,
        launchedAt: Date? = nil,
        cpuPercent: Double,
        isFrontmost: Bool,
        isHidden: Bool,
        isPlayingAudio: Bool,
        windowVisibility: AppWindowVisibility = .unknown,
        isProtectedByMenuBarOverlay: Bool = false,
        isProtectedAudioInfrastructure: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentities = processIdentities
        self.usesApplicationCommands = usesApplicationCommands
        self.launchedAt = launchedAt
        self.cpuPercent = cpuPercent
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.isPlayingAudio = isPlayingAudio
        self.windowVisibility = windowVisibility
        self.isProtectedByMenuBarOverlay = isProtectedByMenuBarOverlay
        self.isProtectedAudioInfrastructure = isProtectedAudioInfrastructure
    }
}

struct ProcessControlSnapshot: Sendable {
    let revision: UInt64
    let statuses: [String: ManagementStatus]
    let estimatedSavedCPUByIdentifier: [String: Double]
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
