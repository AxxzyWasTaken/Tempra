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
    let launchedAt: Date?
    let isRunning: Bool
    let isFrontmost: Bool
    let isHidden: Bool
    let isPlayingAudio: Bool
    let isService: Bool
    let isSystemProcess: Bool
    let status: ManagementStatus
    let rule: AppRule?
    let isAttention: Bool
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
        launchedAt: Date? = nil,
        isRunning: Bool,
        isFrontmost: Bool,
        isHidden: Bool,
        isPlayingAudio: Bool,
        isService: Bool = false,
        isSystemProcess: Bool = false,
        status: ManagementStatus,
        rule: AppRule?,
        isAttention: Bool,
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
        self.launchedAt = launchedAt
        self.isRunning = isRunning
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.isPlayingAudio = isPlayingAudio
        self.isService = isService
        self.isSystemProcess = isSystemProcess
        self.status = status
        self.rule = rule
        self.isAttention = isAttention
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
        guard isRunning else { return "—" }
        return estimatedSavedCPUPercent < 0.05
            ? "0%"
            : String(format: "%.1f%%", estimatedSavedCPUPercent)
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
        isRunning && !isSystemProcess
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
}
