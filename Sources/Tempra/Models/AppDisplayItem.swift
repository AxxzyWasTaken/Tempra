import AppKit
import Foundation

struct AppDisplayItem: Identifiable {
    let bundleIdentifier: String
    let name: String
    let sortName: String
    let applicationURL: URL?
    let iconOverride: NSImage?
    let cpuPercent: Double
    let averageCPUPercent: Double
    let estimatedSavedCPUPercent: Double
    let cpuPowerWatts: Double?
    let estimatedSavedPowerWatts: Double?
    let residentMemoryBytes: UInt64?
    let processCount: Int
    let controllableProcessCount: Int
    let processSamples: [ManagedProcessSample]
    let processProtectionReasons: [ProcessIdentity: Set<ProcessProtectionReason>]
    let launchedAt: Date?
    let isRunning: Bool
    let isFrontmost: Bool
    let isHidden: Bool
    let isPlayingAudio: Bool
    let isService: Bool
    let isBackgroundProcess: Bool
    let isSystemProcess: Bool
    let requiresPrivilegedControl: Bool
    let status: ManagementStatus
    let rule: AppRule?
    let isAttention: Bool
    let isCPULimitSessionActive: Bool
    private let iconCache: AppIconCache?

    init(
        bundleIdentifier: String,
        name: String,
        applicationURL: URL?,
        iconOverride: NSImage? = nil,
        cpuPercent: Double,
        averageCPUPercent: Double,
        estimatedSavedCPUPercent: Double,
        cpuPowerWatts: Double? = nil,
        estimatedSavedPowerWatts: Double? = nil,
        residentMemoryBytes: UInt64? = nil,
        processCount: Int = 0,
        controllableProcessCount: Int = 0,
        processSamples: [ManagedProcessSample] = [],
        processProtectionReasons: [ProcessIdentity: Set<ProcessProtectionReason>] = [:],
        launchedAt: Date? = nil,
        isRunning: Bool,
        isFrontmost: Bool,
        isHidden: Bool,
        isPlayingAudio: Bool,
        isService: Bool = false,
        isBackgroundProcess: Bool = false,
        isSystemProcess: Bool = false,
        requiresPrivilegedControl: Bool? = nil,
        status: ManagementStatus,
        rule: AppRule?,
        isAttention: Bool,
        isCPULimitSessionActive: Bool = false,
        iconCache: AppIconCache? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        sortName = name.lowercased()
        self.applicationURL = applicationURL
        self.iconOverride = iconOverride
        self.cpuPercent = cpuPercent
        self.averageCPUPercent = averageCPUPercent
        self.estimatedSavedCPUPercent = estimatedSavedCPUPercent
        self.cpuPowerWatts = cpuPowerWatts
        self.estimatedSavedPowerWatts = estimatedSavedPowerWatts
        self.residentMemoryBytes = residentMemoryBytes
        self.processCount = processCount
        self.controllableProcessCount = controllableProcessCount
        self.processSamples = processSamples.sorted { $0.identity.pid < $1.identity.pid }
        self.processProtectionReasons = processProtectionReasons
        self.launchedAt = launchedAt
        self.isRunning = isRunning
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.isPlayingAudio = isPlayingAudio
        self.isService = isService
        self.isBackgroundProcess = isBackgroundProcess
        self.isSystemProcess = isSystemProcess
        self.requiresPrivilegedControl = requiresPrivilegedControl ?? isSystemProcess
        self.status = status
        self.rule = rule
        self.isAttention = isAttention
        self.isCPULimitSessionActive = isCPULimitSessionActive
        self.iconCache = iconCache
    }

    var id: String { bundleIdentifier }

    @MainActor
    var icon: NSImage {
        if let iconOverride {
            return iconOverride
        }
        if let iconCache {
            return iconCache.icon(
                bundleIdentifier: bundleIdentifier,
                name: name,
                applicationURL: applicationURL
            )
        }
        if let applicationURL {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: name) ?? NSImage()
    }

    var cpuText: String {
        guard isRunning else { return "—" }
        return cpuPercent < 0.05 ? "0%" : String(format: "%.1f%%", cpuPercent)
    }

    var averageCPUText: String {
        guard isRunning else { return "—" }
        return averageCPUPercent < 0.05 ? "0%" : String(format: "%.1f%%", averageCPUPercent)
    }

    var savedCPUText: String {
        guard isRunning, status.isActivelyLimitingCPU else { return "—" }
        return String(format: "%.1f%%", estimatedSavedCPUPercent)
    }

    var cpuPowerText: String {
        guard isRunning else { return "—" }
        return PowerMetricFormatter.text(watts: cpuPowerWatts)
    }

    var savedPowerText: String {
        guard isRunning else { return "—" }
        return PowerMetricFormatter.text(watts: estimatedSavedPowerWatts)
    }

    var residentMemoryText: String {
        guard isRunning,
              let residentMemoryBytes,
              let byteCount = Int64(exactly: residentMemoryBytes) else {
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .memory)
    }

    var runningTimeText: String {
        guard isRunning, let launchedAt else { return "—" }
        let interval = max(0, Date().timeIntervalSince(launchedAt))
        guard interval.isFinite else { return "—" }
        if interval < 60 { return "Less than a minute" }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "—"
    }

    var canControlApplication: Bool {
        isRunning
            && canManageProcess
            && !requiresPrivilegedControl
            && !BackgroundProcessPolicy.isBackgroundIdentifier(bundleIdentifier)
    }

    var canQuitProcess: Bool {
        isRunning && canManageProcess
    }

    var canLimitCPU: Bool {
        canManageProcess
            && !SystemProcessRulePolicy.isWindowServer(bundleIdentifier: bundleIdentifier)
    }

    var canManageProcess: Bool {
        !isSoundSourceComponent
    }

    var isSoundSourceComponent: Bool {
        SoundSourceCompatibilityPolicy.isProtected(
            bundleIdentifier: bundleIdentifier,
            applicationURL: applicationURL
        )
    }

    var isStandaloneProcess: Bool {
        BackgroundProcessPolicy.isBackgroundIdentifier(bundleIdentifier)
    }

    var ruleSummary: String {
        rule?.summary ?? "Not managed"
    }

    var stateText: String {
        if isAttention {
            return status == .normal ? "High CPU" : "High CPU · \(status.label)"
        }
        if isHidden, status == .normal { return "Hidden" }
        return status.label
    }

    func protectionReasons(
        for sample: ManagedProcessSample
    ) -> [ProcessProtectionReason] {
        var reasons = processProtectionReasons[sample.identity] ?? []
        if rule?.protectAudio == true, sample.isPlayingAudio {
            reasons.insert(.audioPlayback)
        }
        if sample.networkActivity.isLatencySensitive {
            reasons.insert(.networkActivity)
        }
        if !sample.hasCPUMeasurement {
            reasons.insert(.missingCPUMeasurement)
        }
        return ProcessProtectionReason.allCases.filter(reasons.contains)
    }
}
