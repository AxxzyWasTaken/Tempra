import Foundation
import Testing
@testable import Tempra

@Suite("System thermal pressure")
struct SystemMetricsMonitorTests {
    @Test("Known macOS thermal states retain their meaning")
    func knownThermalStatesMapExactly() {
        #expect(SystemMetricsMonitor.thermalPressure(for: .nominal) == .nominal)
        #expect(SystemMetricsMonitor.thermalPressure(for: .fair) == .fair)
        #expect(SystemMetricsMonitor.thermalPressure(for: .serious) == .serious)
        #expect(SystemMetricsMonitor.thermalPressure(for: .critical) == .critical)
    }

    @Test("Unavailable thermal state is not represented as nominal")
    func unavailableThermalStateIsExplicit() {
        #expect(ThermalPressure.unknown.title == "Unavailable")
        #expect(ThermalPressure.unknown.chartValue == nil)
        #expect(SystemCPUSnapshot().thermalPressure == .unknown)
    }

    @Test("History without thermal data migrates to unavailable")
    func missingHistoricalThermalStateIsUnknown() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "date": 0,
            "systemCPUPercent": 20,
            "performanceCPUPercent": 15,
            "efficiencyCPUPercent": 5,
            "estimatedSavedCPUPercent": 2,
            "interventionCount": 1
        ])

        let sample = try JSONDecoder().decode(CPUHistorySample.self, from: data)

        #expect(sample.thermalPressure == .unknown)
        #expect(sample.hasEstimatedSavedCPUMeasurement)
    }

    @Test("Unavailable thermal state survives history persistence")
    func unknownThermalStateRoundTrips() throws {
        let original = CPUHistorySample(
            date: Date(timeIntervalSinceReferenceDate: 10),
            systemCPUPercent: 20,
            performanceCPUPercent: 15,
            efficiencyCPUPercent: 5,
            estimatedSavedCPUPercent: 2,
            thermalPressure: .unknown,
            interventionCount: 1
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(CPUHistorySample.self, from: data)

        #expect(restored == original)
        #expect(restored.thermalPressure == .unknown)
    }

    @Test("Lightweight history remains readable by the previous record shape")
    func lightweightHistoryRetainsLegacySavedCPUField() throws {
        let lightweight = CPUHistorySample(
            date: Date(timeIntervalSinceReferenceDate: 10),
            systemCPUPercent: 20,
            performanceCPUPercent: 15,
            efficiencyCPUPercent: 5,
            estimatedSavedCPUPercent: 0,
            hasEstimatedSavedCPUMeasurement: false,
            interventionCount: 1
        )

        let data = try JSONEncoder().encode(lightweight)
        let restored = try JSONDecoder().decode(CPUHistorySample.self, from: data)
        let legacy = try JSONDecoder().decode(LegacyCPUHistorySample.self, from: data)

        #expect(!restored.hasEstimatedSavedCPUMeasurement)
        #expect(legacy.estimatedSavedCPUPercent == 0)
    }
}

private struct LegacyCPUHistorySample: Decodable {
    let estimatedSavedCPUPercent: Double
}
