import Foundation
import Testing
@testable import Tempra

@Suite("CPU history chart data")
struct CPUHistoryChartDataTests {
    private let endDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("Empty history uses stable bounds and default ceilings")
    func emptyHistory() {
        let data = CPUHistoryChartData(
            samples: [],
            range: .hour,
            endDate: endDate
        )

        #expect(data.chartEndDate == endDate)
        #expect(data.chartStartDate == endDate.addingTimeInterval(-3_600))
        #expect(data.points.isEmpty)
        #expect(data.chartCeiling == 40)
        #expect(data.temperatureFloor == 30)
        #expect(data.temperatureCeiling == 60)
    }

    @Test("Cutoff and gap boundaries preserve samples and segment numbers")
    func cutoffAndGapBoundaries() {
        let cutoff = endDate.addingTimeInterval(-CPUHistoryRange.fiveMinutes.duration)
        let samples = [
            sample(at: cutoff.addingTimeInterval(-0.001)),
            sample(at: cutoff),
            sample(at: cutoff.addingTimeInterval(45)),
            sample(at: cutoff.addingTimeInterval(90.001)),
        ]
        let data = CPUHistoryChartData(
            samples: samples,
            range: .fiveMinutes,
            endDate: endDate
        )

        #expect(data.points.map(\.sample.date) == Array(samples.dropFirst()).map(\.date))
        #expect(data.points.map(\.segment) == [0, 0, 1])
    }

    @Test("Missing temperatures remain absent and use default bounds")
    func missingTemperatures() {
        let data = CPUHistoryChartData(
            samples: [sample(at: endDate, temperature: nil)],
            range: .fiveMinutes,
            endDate: endDate
        )

        #expect(data.points.first?.temperatureChartValue == nil)
        #expect(data.temperatureFloor == 30)
        #expect(data.temperatureCeiling == 60)
    }

    @Test("Temperature values share one derived scale")
    func temperatureScale() {
        let data = CPUHistoryChartData(
            samples: [
                sample(at: endDate.addingTimeInterval(-30), temperature: nil),
                sample(at: endDate.addingTimeInterval(-15), temperature: 75),
                sample(at: endDate, temperature: 90),
            ],
            range: .fiveMinutes,
            endDate: endDate
        )

        #expect(data.chartCeiling == 40)
        #expect(data.temperatureFloor == 60)
        #expect(data.temperatureCeiling == 90)
        #expect(data.points.map(\.temperatureChartValue) == [nil, 20, 40])
        #expect(data.temperatureValue(forChartValue: 0) == 60)
        #expect(data.temperatureValue(forChartValue: 20) == 75)
        #expect(data.temperatureValue(forChartValue: 40) == 90)
    }

    @Test("CPU ceilings retain their threshold boundaries")
    func chartCeilingBoundaries() {
        let cases: [(peak: Double, expectedCeiling: Double)] = [
            (40, 40),
            (40.001, 60),
            (60, 60),
            (60.001, 80),
            (80, 80),
            (80.001, 100),
            (150, 100),
        ]

        for testCase in cases {
            let data = CPUHistoryChartData(
                samples: [sample(at: endDate, systemCPUPercent: testCase.peak)],
                range: .fiveMinutes,
                endDate: endDate
            )
            #expect(data.chartCeiling == testCase.expectedCeiling)
        }
    }

    @Test("Combined performance and efficiency contribution is precomputed")
    func combinedContribution() {
        let data = CPUHistoryChartData(
            samples: [sample(
                at: endDate,
                performanceCPUPercent: 22,
                efficiencyCPUPercent: 13
            )],
            range: .fiveMinutes,
            endDate: endDate
        )

        #expect(data.points.first?.combinedCPUPercent == 35)
    }

    @Test("Day history downsampling retains the first and last samples")
    func dayDownsampling() {
        let samples = fullDaySamples()
        let data = CPUHistoryChartData(
            samples: samples,
            range: .day,
            endDate: endDate
        )

        #expect(data.points.count == 321)
        #expect(data.points.first?.sample.date == samples.first?.date)
        #expect(data.points.last?.sample.date == samples.last?.date)
        #expect(data.points.allSatisfy { $0.segment == 0 })
    }

    @Test("A 5,760-sample render derivation benchmark")
    func fullHistoryBenchmark() {
        let samples = fullDaySamples(includesTemperature: true)
        let clock = ContinuousClock()

        let legacyStart = clock.now
        let legacyChecksum = legacyRenderChecksum(
            samples: samples,
            range: .day,
            endDate: endDate
        )
        let legacyElapsed = legacyStart.duration(to: clock.now)

        let optimizedStart = clock.now
        let data = CPUHistoryChartData(
            samples: samples,
            range: .day,
            endDate: endDate
        )
        let optimizedElapsed = optimizedStart.duration(to: clock.now)

        #expect(legacyChecksum.pointCount == data.points.count * 6)
        #expect(legacyChecksum.value.isFinite)
        #expect(data.points.count == 321)
        print(
            "CPU history benchmark: 5760 samples; legacy \(legacyElapsed); "
                + "derived snapshot \(optimizedElapsed)"
        )
    }

    private func fullDaySamples(includesTemperature: Bool = false) -> [CPUHistorySample] {
        (0..<5_760).map { index in
            let secondsFromEnd = TimeInterval(5_759 - index) * 15
            return sample(
                at: endDate.addingTimeInterval(-secondsFromEnd),
                systemCPUPercent: Double(index % 101),
                performanceCPUPercent: Double(index % 31),
                efficiencyCPUPercent: Double(index % 17),
                savedCPUPercent: Double(index % 41),
                temperature: includesTemperature ? Double(45 + index % 46) : nil
            )
        }
    }

    private func sample(
        at date: Date,
        systemCPUPercent: Double = 0,
        performanceCPUPercent: Double = 0,
        efficiencyCPUPercent: Double = 0,
        savedCPUPercent: Double = 0,
        temperature: Double? = nil
    ) -> CPUHistorySample {
        CPUHistorySample(
            date: date,
            systemCPUPercent: systemCPUPercent,
            performanceCPUPercent: performanceCPUPercent,
            efficiencyCPUPercent: efficiencyCPUPercent,
            estimatedSavedCPUPercent: savedCPUPercent,
            cpuTemperatureCelsius: temperature,
            interventionCount: 0
        )
    }

    private func legacyRenderChecksum(
        samples: [CPUHistorySample],
        range: CPUHistoryRange,
        endDate: Date
    ) -> (pointCount: Int, value: Double) {
        var pointCount = 0
        var value = 0.0
        for pass in 0..<6 {
            for point in legacyChartPoints(samples: samples, range: range, endDate: endDate) {
                pointCount += 1
                value += point.sample.systemCPUPercent + Double(point.segment)
                if pass == 4, let temperature = point.sample.cpuTemperatureCelsius {
                    value += legacyChartValue(
                        forTemperature: temperature,
                        samples: samples,
                        range: range,
                        endDate: endDate
                    )
                }
            }
        }
        value += legacyChartCeiling(samples: samples, range: range, endDate: endDate)
        return (pointCount, value)
    }

    private func legacyChartPoints(
        samples: [CPUHistorySample],
        range: CPUHistoryRange,
        endDate: Date
    ) -> [(sample: CPUHistorySample, segment: Int)] {
        var segment = 0
        var previousDate: Date?
        let gapLimit = max(45, range.duration / 120)
        return legacyVisibleSamples(samples: samples, range: range, endDate: endDate).map { sample in
            if let previousDate,
               sample.date.timeIntervalSince(previousDate) > gapLimit {
                segment += 1
            }
            previousDate = sample.date
            return (sample, segment)
        }
    }

    private func legacyChartValue(
        forTemperature temperature: Double,
        samples: [CPUHistorySample],
        range: CPUHistoryRange,
        endDate: Date
    ) -> Double {
        let temperatureCeiling = legacyVisibleSamples(
            samples: samples,
            range: range,
            endDate: endDate
        ).compactMap(\.cpuTemperatureCelsius).max().map { peak in
            peak > 60 ? ceil(peak / 15) * 15 : 60
        } ?? 60
        let fraction = (temperature - (temperatureCeiling - 30)) / 30
        let chartCeiling = legacyChartCeiling(
            samples: samples,
            range: range,
            endDate: endDate
        )
        return min(chartCeiling, max(0, fraction * chartCeiling))
    }

    private func legacyChartCeiling(
        samples: [CPUHistorySample],
        range: CPUHistoryRange,
        endDate: Date
    ) -> Double {
        let peak = legacyVisibleSamples(
            samples: samples,
            range: range,
            endDate: endDate
        ).reduce(0.0) { result, sample in
            max(
                result,
                sample.systemCPUPercent,
                sample.efficiencyCPUPercent + sample.performanceCPUPercent,
                sample.estimatedSavedCPUPercent
            )
        }
        if peak <= 40 { return 40 }
        if peak <= 60 { return 60 }
        if peak <= 80 { return 80 }
        return 100
    }

    private func legacyVisibleSamples(
        samples: [CPUHistorySample],
        range: CPUHistoryRange,
        endDate: Date
    ) -> [CPUHistorySample] {
        let cutoffDate = endDate.addingTimeInterval(-range.duration)
        let filtered = samples.filter { $0.date >= cutoffDate }
        guard range == .day, filtered.count > 320 else { return filtered }
        let step = max(1, filtered.count / 320)
        return filtered.enumerated().compactMap { index, sample in
            if index.isMultiple(of: step) || index == filtered.count - 1 {
                return sample
            }
            return nil
        }
    }
}
