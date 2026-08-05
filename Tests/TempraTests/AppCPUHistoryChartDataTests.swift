import Foundation
import Testing
@testable import Tempra

@Suite("Application CPU history chart data")
struct AppCPUHistoryChartDataTests {
    @Test("Chart data filters, sorts, and scales the selected range")
    func rangeAndScale() {
        let endDate = Date(timeIntervalSince1970: 10_000)
        let samples = [
            sample(at: endDate.addingTimeInterval(-3_700), cpu: 90, saved: 2),
            sample(at: endDate.addingTimeInterval(-10), cpu: 31, saved: 54),
            sample(at: endDate.addingTimeInterval(-20), cpu: 12, saved: 3),
            sample(at: endDate.addingTimeInterval(10), cpu: 99, saved: 1)
        ]

        let data = AppCPUHistoryChartData(
            samples: samples,
            range: .hour,
            endDate: endDate
        )

        #expect(data.points.map(\.sample.cpuPercent) == [12, 31])
        #expect(data.ceiling == 75)
        #expect(data.startDate == endDate.addingTimeInterval(-3_600))
        #expect(data.endDate == endDate)
    }

    @Test("Chart data limits dense histories")
    func downsamplingBound() {
        let endDate = Date(timeIntervalSince1970: 20_000)
        let samples = (0..<361).map { index in
            sample(
                at: endDate.addingTimeInterval(TimeInterval(index - 360)),
                cpu: Double(index),
                saved: 0
            )
        }

        let data = AppCPUHistoryChartData(
            samples: samples,
            range: .fiveMinutes,
            endDate: endDate
        )

        #expect(data.points.count <= 181)
        #expect(data.points.last?.sample.date == endDate)
    }

    @Test("Chart data separates collection gaps")
    func separatesCollectionGaps() {
        let endDate = Date(timeIntervalSince1970: 30_000)
        let samples = [
            sample(at: endDate.addingTimeInterval(-300), cpu: 10, saved: 2),
            sample(at: endDate.addingTimeInterval(-270), cpu: 12, saved: 3),
            sample(at: endDate.addingTimeInterval(-30), cpu: 15, saved: 4),
            sample(at: endDate, cpu: 17, saved: 5)
        ]

        let data = AppCPUHistoryChartData(
            samples: samples,
            range: .fiveMinutes,
            endDate: endDate
        )

        #expect(data.points.map(\.segment) == [0, 0, 1, 1])
    }

    private func sample(
        at date: Date,
        cpu: Double,
        saved: Double
    ) -> AppCPUHistorySample {
        AppCPUHistorySample(
            bundleIdentifier: "com.example.app",
            date: date,
            cpuPercent: cpu,
            estimatedSavedCPUPercent: saved
        )
    }
}
