import AppKit
import Foundation

enum ManagementStatus: Equatable, Sendable {
    case normal
    case waiting
    case limited(Double)
    case paused
    case energyEfficient
    case audioProtected
    case snoozed(Date)
    case disabled
    case notRunning
    case unavailable

    var label: String {
        switch self {
        case .normal: "Normal"
        case .waiting: "Waiting"
        case .limited(let percent): "Limited to \(Int(percent))%"
        case .paused: "Paused"
        case .energyEfficient: "Power-saving cores"
        case .audioProtected: "Audio active"
        case .snoozed(let until): "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"
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
        case .paused: "pause.circle.fill"
        case .energyEfficient: "leaf.fill"
        case .audioProtected: "speaker.wave.2.fill"
        case .snoozed: "moon.zzz.fill"
        case .disabled: "slash.circle.fill"
        case .notRunning: "app.dashed"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    var isActiveManagement: Bool {
        switch self {
        case .waiting, .limited, .paused, .energyEfficient, .audioProtected:
            true
        case .normal, .snoozed, .disabled, .notRunning, .unavailable:
            false
        }
    }

    var isActivelySavingPower: Bool {
        switch self {
        case .limited, .paused, .energyEfficient:
            true
        case .normal, .waiting, .audioProtected, .snoozed, .disabled, .notRunning,
                .unavailable:
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
    let launchedAt: Date?
    let cpuPercent: Double
    var isFrontmost: Bool
    var isHidden: Bool
    let isPlayingAudio: Bool
    let isSystemProcess: Bool
    var windowVisibility: AppWindowVisibility
    var isProtectedByMenuBarOverlay: Bool
    var cpuPowerWatts: Double? = nil
    var cpuEnergyJoulesPerCPUSecond: Double? = nil
    var status: ManagementStatus

    init(
        bundleIdentifier: String,
        name: String,
        bundleURL: URL?,
        processIdentifiers: [pid_t],
        processIdentities: [ProcessIdentity] = [],
        launchedAt: Date? = nil,
        cpuPercent: Double,
        isFrontmost: Bool,
        isHidden: Bool,
        isPlayingAudio: Bool,
        isSystemProcess: Bool,
        windowVisibility: AppWindowVisibility = .unknown,
        isProtectedByMenuBarOverlay: Bool = false,
        cpuPowerWatts: Double? = nil,
        cpuEnergyJoulesPerCPUSecond: Double? = nil,
        status: ManagementStatus
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundleURL = bundleURL
        self.processIdentifiers = processIdentifiers
        self.processIdentities = processIdentities
        self.launchedAt = launchedAt
        self.cpuPercent = cpuPercent
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.isPlayingAudio = isPlayingAudio
        self.isSystemProcess = isSystemProcess
        self.windowVisibility = windowVisibility
        self.isProtectedByMenuBarOverlay = isProtectedByMenuBarOverlay
        self.cpuPowerWatts = cpuPowerWatts
        self.cpuEnergyJoulesPerCPUSecond = cpuEnergyJoulesPerCPUSecond
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
