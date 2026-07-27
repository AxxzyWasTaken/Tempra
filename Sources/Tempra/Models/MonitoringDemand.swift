import Foundation

enum MonitoringDemand: Equatable {
    case dormant
    case menuBar
    case liveUI
    case continuous

    var sampleInterval: TimeInterval? {
        switch self {
        case .dormant:
            nil
        case .menuBar, .continuous:
            5
        case .liveUI:
            1
        }
    }

    var temperatureInterval: TimeInterval? {
        switch self {
        case .dormant, .menuBar:
            nil
        case .liveUI:
            2
        case .continuous:
            15
        }
    }

    var samplesPower: Bool {
        self == .liveUI
    }

    var samplesApplications: Bool {
        self == .liveUI || self == .continuous
    }

    static func resolve(
        isPresentationActive: Bool,
        isContinuousMonitoringEnabled: Bool,
        showsCPUUsageInMenuBar: Bool
    ) -> MonitoringDemand {
        if isPresentationActive {
            return .liveUI
        }
        if isContinuousMonitoringEnabled {
            return .continuous
        }
        return showsCPUUsageInMenuBar ? .menuBar : .dormant
    }
}
