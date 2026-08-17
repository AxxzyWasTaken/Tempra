import AppKit
import Foundation

enum ManagementStatus: Equatable, Sendable {
    case normal
    case waiting
    case limited(Double)
    case limitedWithProtectedProcesses(Double)
    case paused
    case lowerPriority
    case audioProtected
    case networkProtected
    case snoozed(Date)
    case managementPaused(Date)
    case disabled
    case notRunning
    case unavailable

    var label: String {
        switch self {
        case .normal: "Normal"
        case .waiting: "Waiting"
        case .limited(let percent): "Limited to \(Int(percent))%"
        case .limitedWithProtectedProcesses: "Best-effort CPU limit"
        case .paused: "Paused"
        case .lowerPriority: "Lower CPU priority"
        case .audioProtected: "Audio active"
        case .networkProtected: "Network active"
        case .snoozed(let until):
            "Resumed until \(until.formatted(date: .omitted, time: .shortened))"
        case .managementPaused(let until):
            "Management paused until \(until.formatted(date: .omitted, time: .shortened))"
        case .disabled: "Disabled"
        case .notRunning: "Not running"
        case .unavailable: "Unavailable"
        }
    }

    var symbolName: String {
        switch self {
        case .normal: "circle.fill"
        case .waiting: "clock.fill"
        case .limited: "gauge.with.dots.needle.33percent"
        case .limitedWithProtectedProcesses: "gauge.with.dots.needle.33percent"
        case .paused: "pause.circle.fill"
        case .lowerPriority: "arrow.down.circle.fill"
        case .audioProtected: "speaker.wave.2.fill"
        case .networkProtected: "network"
        case .snoozed: "moon.zzz.fill"
        case .managementPaused: "pause.circle.fill"
        case .disabled: "slash.circle.fill"
        case .notRunning: "app.dashed"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    var isActiveManagement: Bool {
        switch self {
        case .waiting, .limited, .limitedWithProtectedProcesses, .paused,
                .lowerPriority, .audioProtected, .networkProtected:
            true
        case .normal, .snoozed, .managementPaused, .disabled, .notRunning,
                .unavailable:
            false
        }
    }

    var isActivelySavingPower: Bool {
        switch self {
        case .limited, .limitedWithProtectedProcesses, .paused, .lowerPriority:
            true
        case .normal, .waiting, .audioProtected, .networkProtected, .snoozed,
                .managementPaused, .disabled, .notRunning, .unavailable:
            false
        }
    }

    var isActivelyLimitingCPU: Bool {
        switch self {
        case .limited, .limitedWithProtectedProcesses, .paused:
            true
        case .normal, .waiting, .lowerPriority, .audioProtected, .networkProtected,
                .snoozed, .managementPaused, .disabled, .notRunning, .unavailable:
            false
        }
    }
}

struct ManagedApp: Identifiable, Sendable {
    let bundleIdentifier: String
    let name: String
    let bundleURL: URL?
    let processIdentifiers: [pid_t]
    let processIdentities: [ProcessIdentity]
    let processSamples: [ManagedProcessSample]
    let launchedAt: Date?
    let cpuPercent: Double
    let residentMemoryBytes: UInt64?
    var isFrontmost: Bool
    var isHidden: Bool
    var isPlayingAudio: Bool
    let isService: Bool
    let isBackgroundProcess: Bool
    let isSystemProcess: Bool
    let isCurrentApplication: Bool
    let requiresPrivilegedControl: Bool
    var windowVisibility: AppWindowVisibility
    var isProtectedByForegroundOverlay: Bool
    var status: ManagementStatus

    init(
        bundleIdentifier: String,
        name: String,
        bundleURL: URL?,
        processIdentifiers: [pid_t],
        processIdentities: [ProcessIdentity] = [],
        processSamples: [ManagedProcessSample]? = nil,
        launchedAt: Date? = nil,
        cpuPercent: Double,
        residentMemoryBytes: UInt64? = nil,
        isFrontmost: Bool,
        isHidden: Bool,
        isPlayingAudio: Bool,
        isService: Bool = false,
        isBackgroundProcess: Bool = false,
        isSystemProcess: Bool,
        isCurrentApplication: Bool = false,
        requiresPrivilegedControl: Bool? = nil,
        windowVisibility: AppWindowVisibility = .unknown,
        isProtectedByForegroundOverlay: Bool = false,
        status: ManagementStatus
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundleURL = bundleURL
        self.processIdentifiers = processIdentifiers
        self.processIdentities = processIdentities
        if let processSamples {
            self.processSamples = processSamples.sorted { $0.identity.pid < $1.identity.pid }
        } else {
            let sampleCPU = processIdentities.isEmpty
                ? 0
                : max(0, cpuPercent) / Double(processIdentities.count)
            self.processSamples = processIdentities.enumerated().map { index, identity in
                ManagedProcessSample(
                    identity: identity,
                    cpuPercent: sampleCPU,
                    isMainProcess: index == 0,
                    isPlayingAudio: isPlayingAudio
                )
            }
        }
        self.launchedAt = launchedAt
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.isPlayingAudio = isPlayingAudio
        self.isService = isService
        self.isBackgroundProcess = isBackgroundProcess
        self.isSystemProcess = isSystemProcess
        self.isCurrentApplication = isCurrentApplication
        self.requiresPrivilegedControl = requiresPrivilegedControl
            ?? (processIdentities.contains(where: \.requiresPrivilegedControl)
                || (isSystemProcess && processIdentities.isEmpty))
        self.windowVisibility = windowVisibility
        self.isProtectedByForegroundOverlay = isProtectedByForegroundOverlay
        self.status = status
    }

    var id: String { bundleIdentifier }

    var icon: NSImage {
        guard let bundleURL else {
            return NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: name)
                ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }
}
