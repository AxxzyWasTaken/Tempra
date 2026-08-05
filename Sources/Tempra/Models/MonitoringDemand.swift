import Foundation

enum MonitoringDemand: Equatable {
    case dormant
    case menuBar
    case management(samplesSystemCPU: Bool)
    case highCPUAlerts(samplesSystemCPU: Bool)
    case liveUI
    case continuous
    case continuousManagement

    var sampleInterval: TimeInterval? {
        switch self {
        case .dormant:
            nil
        case .menuBar, .management, .highCPUAlerts, .continuous,
                .continuousManagement:
            5
        case .liveUI:
            1
        }
    }

    var temperatureInterval: TimeInterval? {
        switch self {
        case .dormant, .menuBar, .management, .highCPUAlerts:
            nil
        case .liveUI:
            2
        case .continuous, .continuousManagement:
            15
        }
    }

    var processTableRefreshInterval: TimeInterval {
        switch self {
        case .liveUI:
            5
        case .continuous, .continuousManagement:
            15
        case .dormant, .menuBar, .management, .highCPUAlerts:
            30
        }
    }

    var refreshesAudioActivity: Bool {
        self == .liveUI
    }

    var samplesApplications: Bool {
        switch self {
        case .management, .highCPUAlerts, .liveUI, .continuous,
                .continuousManagement:
            true
        case .dormant, .menuBar:
            false
        }
    }

    var recordsApplicationMetrics: Bool {
        self == .liveUI || self == .continuous || self == .continuousManagement
    }

    var detectsHighCPU: Bool {
        switch self {
        case .highCPUAlerts, .liveUI, .continuous, .continuousManagement:
            true
        case .dormant, .menuBar, .management:
            false
        }
    }

    var samplesSystemCPU: Bool {
        switch self {
        case .dormant:
            false
        case .management(let samplesSystemCPU):
            samplesSystemCPU
        case .highCPUAlerts(let samplesSystemCPU):
            samplesSystemCPU
        case .menuBar, .liveUI, .continuous, .continuousManagement:
            true
        }
    }

    static func resolve(
        isPresentationActive: Bool,
        isContinuousMonitoringEnabled: Bool,
        showsCPUUsageInMenuBar: Bool,
        requiresContextMonitoring: Bool = false,
        requiresHighCPUDetection: Bool = false,
        requiresApplicationMonitoring: Bool = false
    ) -> MonitoringDemand {
        if isPresentationActive {
            return .liveUI
        }
        if isContinuousMonitoringEnabled, requiresApplicationMonitoring {
            return .continuousManagement
        }
        if isContinuousMonitoringEnabled {
            return .continuous
        }
        if requiresHighCPUDetection {
            return .highCPUAlerts(
                samplesSystemCPU: showsCPUUsageInMenuBar || requiresContextMonitoring
            )
        }
        if requiresApplicationMonitoring {
            return .management(
                samplesSystemCPU: showsCPUUsageInMenuBar || requiresContextMonitoring
            )
        }
        return showsCPUUsageInMenuBar || requiresContextMonitoring ? .menuBar : .dormant
    }
}
