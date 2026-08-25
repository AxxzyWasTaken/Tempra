import Foundation
import Testing
@testable import Tempra

@Suite("Application GPU power chart data")
struct AppGPUPowerChartDataTests {
    @Test("The strip reports the peak of the visible range")
    func peakFollowsTheRange() {
        let endDate = Date(timeIntervalSince1970: 10_000)
        let samples = [
            // Outside the hour, and the highest reading of all: it must not count.
            sample(at: endDate.addingTimeInterval(-3_700), watts: 90),
            sample(at: endDate.addingTimeInterval(-600), watts: 4.5),
            sample(at: endDate.addingTimeInterval(-120), watts: 18.25),
            sample(at: endDate.addingTimeInterval(-30), watts: 6)
        ]

        let data = AppGPUPowerChartData(
            samples: samples,
            range: .hour,
            endDate: endDate
        )

        #expect(data.peakWatts == 18.25)
        #expect(data.hasGPUWork)
        #expect(data.points.count == 3)
        #expect(data.startDate == endDate.addingTimeInterval(-3_600))
    }

    @Test("An idle GPU reports no work instead of a flat line")
    func idleRangeHasNoWork() {
        let endDate = Date(timeIntervalSince1970: 20_000)
        let samples = (1...5).map {
            sample(at: endDate.addingTimeInterval(TimeInterval(-$0 * 10)), watts: 0)
        }

        let data = AppGPUPowerChartData(
            samples: samples,
            range: .fiveMinutes,
            endDate: endDate
        )

        #expect(!data.hasGPUWork)
        #expect(data.peakWatts == 0)
        #expect(data.ceiling == 1)
    }

    @Test("The plot keeps the ceiling line in view")
    func ceilingLeavesRoomForTheLimit() {
        let endDate = Date(timeIntervalSince1970: 30_000)
        let samples = [sample(at: endDate.addingTimeInterval(-10), watts: 2)]

        // A limit far above the measured draw still has to be visible, which is
        // exactly the case that tells the user the limit will never act.
        let withLimit = AppGPUPowerChartData(
            samples: samples,
            range: .fiveMinutes,
            endDate: endDate,
            limitWatts: 40
        )
        #expect(withLimit.ceiling >= 40)

        let withoutLimit = AppGPUPowerChartData(
            samples: samples,
            range: .fiveMinutes,
            endDate: endDate
        )
        #expect(withoutLimit.ceiling >= 2)
        #expect(withoutLimit.ceiling <= 5)
    }

    @Test("A heavy range rounds the scale to readable steps")
    func heavyRangeRoundsTheScale() {
        let endDate = Date(timeIntervalSince1970: 40_000)
        let samples = [sample(at: endDate.addingTimeInterval(-5), watts: 62)]

        let data = AppGPUPowerChartData(
            samples: samples,
            range: .fiveMinutes,
            endDate: endDate
        )

        #expect(data.ceiling == 80)
    }

    @Test("History saved before GPU limits reads as no GPU work")
    func legacyHistoryDecodesWithoutPower() throws {
        let stored = Data("""
        [{
            "bundleIdentifier": "com.example.app",
            "date": 760000000,
            "cpuPercent": 42,
            "estimatedSavedCPUPercent": 8
        }]
        """.utf8)

        let decoded = try JSONDecoder().decode([AppCPUHistorySample].self, from: stored)
        #expect(decoded.first?.gpuWatts == 0)
        #expect(decoded.first?.cpuPercent == 42)
    }

    private func sample(at date: Date, watts: Double) -> AppCPUHistorySample {
        AppCPUHistorySample(
            bundleIdentifier: "com.example.app",
            date: date,
            cpuPercent: 5,
            estimatedSavedCPUPercent: 0,
            gpuWatts: watts
        )
    }
}
