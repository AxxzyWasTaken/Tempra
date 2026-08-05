import Foundation

struct CPUHistorySample: Codable, Equatable, Identifiable {
    let date: Date
    let systemCPUPercent: Double
    let performanceCPUPercent: Double
    let efficiencyCPUPercent: Double
    let estimatedSavedCPUPercent: Double
    let hasEstimatedSavedCPUMeasurement: Bool
    let cpuTemperatureCelsius: Double?
    let thermalPressure: ThermalPressure
    let interventionCount: Int

    var id: Date { date }

    init(
        date: Date,
        systemCPUPercent: Double,
        performanceCPUPercent: Double,
        efficiencyCPUPercent: Double,
        estimatedSavedCPUPercent: Double,
        hasEstimatedSavedCPUMeasurement: Bool = true,
        cpuTemperatureCelsius: Double? = nil,
        thermalPressure: ThermalPressure = .unknown,
        interventionCount: Int
    ) {
        self.date = date
        self.systemCPUPercent = systemCPUPercent
        self.performanceCPUPercent = performanceCPUPercent
        self.efficiencyCPUPercent = efficiencyCPUPercent
        self.estimatedSavedCPUPercent = estimatedSavedCPUPercent
        self.hasEstimatedSavedCPUMeasurement = hasEstimatedSavedCPUMeasurement
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.thermalPressure = thermalPressure
        self.interventionCount = interventionCount
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case systemCPUPercent
        case performanceCPUPercent
        case efficiencyCPUPercent
        case estimatedSavedCPUPercent
        case hasEstimatedSavedCPUMeasurement
        case cpuTemperatureCelsius
        case thermalPressure
        case interventionCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        systemCPUPercent = try container.decode(Double.self, forKey: .systemCPUPercent)
        performanceCPUPercent = try container.decode(Double.self, forKey: .performanceCPUPercent)
        efficiencyCPUPercent = try container.decode(Double.self, forKey: .efficiencyCPUPercent)
        estimatedSavedCPUPercent = try container.decode(
            Double.self,
            forKey: .estimatedSavedCPUPercent
        )
        hasEstimatedSavedCPUMeasurement = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasEstimatedSavedCPUMeasurement
        ) ?? true
        cpuTemperatureCelsius = try container.decodeIfPresent(
            Double.self,
            forKey: .cpuTemperatureCelsius
        )
        thermalPressure = try container.decodeIfPresent(
            ThermalPressure.self,
            forKey: .thermalPressure
        ) ?? .unknown
        interventionCount = try container.decode(Int.self, forKey: .interventionCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(systemCPUPercent, forKey: .systemCPUPercent)
        try container.encode(performanceCPUPercent, forKey: .performanceCPUPercent)
        try container.encode(efficiencyCPUPercent, forKey: .efficiencyCPUPercent)
        try container.encode(estimatedSavedCPUPercent, forKey: .estimatedSavedCPUPercent)
        if !hasEstimatedSavedCPUMeasurement {
            try container.encode(false, forKey: .hasEstimatedSavedCPUMeasurement)
        }
        try container.encodeIfPresent(cpuTemperatureCelsius, forKey: .cpuTemperatureCelsius)
        try container.encode(thermalPressure, forKey: .thermalPressure)
        try container.encode(interventionCount, forKey: .interventionCount)
    }
}

struct AppCPUHistorySample: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    let date: Date
    let cpuPercent: Double
    let estimatedSavedCPUPercent: Double

    var id: Date { date }
}

enum ThermalPressure: String, Codable, Equatable {
    case unknown
    case nominal
    case fair
    case serious
    case critical

    var title: String {
        switch self {
        case .unknown: "Unavailable"
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    var chartValue: Double? {
        switch self {
        case .unknown: nil
        case .nominal: 10
        case .fair: 30
        case .serious: 60
        case .critical: 90
        }
    }
}

struct SystemCPUSnapshot: Equatable, Sendable {
    var totalPercent: Double = 0
    var performancePercent: Double = 0
    var efficiencyPercent: Double = 0
    var performanceCoreCount: Int = 0
    var efficiencyCoreCount: Int = 0
    var cpuTemperatureCelsius: Double?
    var thermalPressure: ThermalPressure = .unknown
}

struct ManagementDurationSummary: Equatable, Identifiable {
    let bundleIdentifier: String
    let displayName: String
    let applicationURL: URL?
    let limitedDuration: TimeInterval
    let pausedDuration: TimeInterval

    var id: String { bundleIdentifier }
    var totalDuration: TimeInterval { limitedDuration + pausedDuration }
    var isMostlyPaused: Bool { pausedDuration > limitedDuration }
}
