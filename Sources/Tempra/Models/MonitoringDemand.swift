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

    /// The smallest gap between two event-driven samples.
    ///
    /// A process table that churns — an app that spawns short-lived children,
    /// a run of app launches — fires change events several times a second, and
    /// every sample walks the whole process table. The open interface follows
    /// them, because the list is on screen. Every other mode paces them: the
    /// rules only need the change within a second, and the scan is the cost.
    var eventRefreshInterval: TimeInterval {
        switch self {
        case .liveUI:
            0
        case .dormant, .menuBar, .management, .highCPUAlerts, .continuous,
                .continuousManagement:
            1
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

    /// Whether the apps under a rule get history while the interface is closed.
    ///
    /// A limit is chosen against what the app draws over a session, so the apps
    /// carrying rules need history even when nobody is watching. This stays
    /// narrow: the managed apps only, never the whole process list.
    var recordsManagedApplicationMetrics: Bool {
        switch self {
        case .management, .highCPUAlerts:
            true
        case .dormant, .menuBar, .liveUI, .continuous, .continuousManagement:
            false
        }
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
