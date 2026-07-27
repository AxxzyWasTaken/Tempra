import Darwin
import Foundation

struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startTimeMicroseconds: UInt64
}

struct ProcessControlTarget: Sendable {
    let bundleIdentifier: String
    let processIdentities: Set<ProcessIdentity>
    let launchedAt: Date?
    let cpuPercent: Double
    let isFrontmost: Bool
    let isHidden: Bool
    let isPlayingAudio: Bool
    var windowVisibility: AppWindowVisibility
    let isProtectedByMenuBarOverlay: Bool

    init(
        bundleIdentifier: String,
        processIdentities: Set<ProcessIdentity>,
        launchedAt: Date? = nil,
        cpuPercent: Double,
        isFrontmost: Bool,
        isHidden: Bool,
        isPlayingAudio: Bool,
        windowVisibility: AppWindowVisibility = .unknown,
        isProtectedByMenuBarOverlay: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentities = processIdentities
        self.launchedAt = launchedAt
        self.cpuPercent = cpuPercent
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.isPlayingAudio = isPlayingAudio
        self.windowVisibility = windowVisibility
        self.isProtectedByMenuBarOverlay = isProtectedByMenuBarOverlay
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
        bundleIdentifier: String,
        previous: ManagementStatus,
        current: ManagementStatus
    )
    case activity(bundleIdentifier: String, kind: ActivityKind, detail: String)
    case pauseWakeMonitoringChanged(Bool)
}
