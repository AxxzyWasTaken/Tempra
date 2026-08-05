import Foundation

enum MonitoringDemand: Equatable {
    case dormant
    case menuBar
    case management(samplesSystemCPU: Bool)
    case liveUI
    case continuous
    case continuousManagement

    var sampleInterval: TimeInterval? {
        switch self {
        case .dormant:
            nil
        case .menuBar, .continuous:
            5
        case .management, .liveUI, .continuousManagement:
            1
        }
    }

    var temperatureInterval: TimeInterval? {
        switch self {
        case .dormant, .menuBar, .management:
            nil
        case .liveUI:
            2
        case .continuous, .continuousManagement:
            15
        }
    }

    var samplesPower: Bool {
        self == .liveUI
    }

    var samplesApplications: Bool {
        switch self {
        case .management, .liveUI, .continuous, .continuousManagement:
            true
        case .dormant, .menuBar:
            false
        }
    }

    var recordsApplicationMetrics: Bool {
        self == .liveUI || self == .continuous || self == .continuousManagement
    }

    var samplesSystemCPU: Bool {
        switch self {
        case .dormant:
            false
        case .management(let samplesSystemCPU):
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
        if requiresApplicationMonitoring {
            return .management(
                samplesSystemCPU: showsCPUUsageInMenuBar || requiresContextMonitoring
            )
        }
        return showsCPUUsageInMenuBar || requiresContextMonitoring ? .menuBar : .dormant
    }
}
