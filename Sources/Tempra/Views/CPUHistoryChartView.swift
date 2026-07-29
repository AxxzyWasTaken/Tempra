import Charts
import SwiftUI

struct CPUHistoryChartData {
    struct Point: Identifiable, Equatable {
        let sample: CPUHistorySample
        let segment: Int
        let combinedCPUPercent: Double
        let temperatureChartValue: Double?

        var id: Date { sample.date }
    }

    let chartStartDate: Date
    let chartEndDate: Date
    let points: [Point]
    let chartCeiling: Double
    let temperatureFloor: Double
    let temperatureCeiling: Double

    init(
        samples: [CPUHistorySample],
        range: CPUHistoryRange,
        endDate: Date
    ) {
        let resolvedChartStartDate = endDate.addingTimeInterval(-range.duration)
        chartEndDate = endDate
        chartStartDate = resolvedChartStartDate

        let filteredSamples = samples.filter { $0.date >= resolvedChartStartDate }
        let visibleSamples: [CPUHistorySample]
        if range == .day, filteredSamples.count > 320 {
            let step = max(1, filteredSamples.count / 320)
            visibleSamples = filteredSamples.enumerated().compactMap { index, sample in
                if index.isMultiple(of: step) || index == filteredSamples.count - 1 {
                    return sample
                }
                return nil
            }
        } else {
            visibleSamples = filteredSamples
        }

        let cpuPeak = visibleSamples.reduce(0.0) { result, sample in
            max(
                result,
                sample.systemCPUPercent,
                sample.efficiencyCPUPercent + sample.performanceCPUPercent,
                sample.estimatedSavedCPUPercent
            )
        }
        let resolvedChartCeiling = Self.chartCeiling(for: cpuPeak)
        let temperaturePeak = visibleSamples.compactMap(\.cpuTemperatureCelsius).max() ?? 60
        let resolvedTemperatureCeiling = temperaturePeak > 60
            ? ceil(temperaturePeak / 15) * 15
            : 60
        let resolvedTemperatureFloor = resolvedTemperatureCeiling - 30

        chartCeiling = resolvedChartCeiling
        temperatureCeiling = resolvedTemperatureCeiling
        temperatureFloor = resolvedTemperatureFloor

        var segment = 0
        var previousDate: Date?
        let gapLimit = max(45, range.duration / 120)
        points = visibleSamples.map { sample in
            if let previousDate,
               sample.date.timeIntervalSince(previousDate) > gapLimit {
                segment += 1
            }
            previousDate = sample.date
            let combinedCPUPercent = sample.efficiencyCPUPercent
                + sample.performanceCPUPercent
            let temperatureChartValue = sample.cpuTemperatureCelsius.map { temperature in
                let fraction = (temperature - resolvedTemperatureFloor) / 30
                return min(
                    resolvedChartCeiling,
                    max(0, fraction * resolvedChartCeiling)
                )
            }
            return Point(
                sample: sample,
                segment: segment,
                combinedCPUPercent: combinedCPUPercent,
                temperatureChartValue: temperatureChartValue
            )
        }
    }

    func temperatureValue(forChartValue value: Double) -> Double {
        temperatureFloor + value / chartCeiling * 30
    }

    private static func chartCeiling(for peak: Double) -> Double {
        if peak <= 40 { return 40 }
        if peak <= 60 { return 60 }
        if peak <= 80 { return 80 }
        return 100
    }
}

struct CPUHistoryChartView: View {
    let samples: [CPUHistorySample]
    @Binding var range: CPUHistoryRange
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int

    var body: some View {
        let chartData = CPUHistoryChartData(
            samples: samples,
            range: range,
            endDate: Date()
        )

        GeometryReader { geometry in
            ZStack {
                Chart {
                ForEach(chartData.points) { point in
                    AreaMark(
                        x: .value("Time", point.sample.date),
                        yStart: .value("Efficiency Start", 0),
                        yEnd: .value("Efficiency", point.sample.efficiencyCPUPercent),
                        series: .value("Series", "Efficiency-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.efficiencyArea)
                    .interpolationMethod(.linear)
                }

                ForEach(chartData.points) { point in
                    AreaMark(
                        x: .value("Time", point.sample.date),
                        yStart: .value(
                            "Performance Start",
                            point.sample.efficiencyCPUPercent
                        ),
                        yEnd: .value(
                            "Performance",
                            point.combinedCPUPercent
                        ),
                        series: .value("Series", "Performance-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.performanceArea)
                    .interpolationMethod(.linear)
                }

                ForEach(chartData.points) { point in
                    LineMark(
                        x: .value("Time", point.sample.date),
                        y: .value("Efficiency Boundary", point.sample.efficiencyCPUPercent),
                        series: .value("Series", "Efficiency Boundary-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.efficiency.opacity(0.80))
                    .lineStyle(StrokeStyle(lineWidth: 0.65, lineJoin: .round))
                    .interpolationMethod(.linear)
                }

                ForEach(chartData.points) { point in
                    LineMark(
                        x: .value("Time", point.sample.date),
                        y: .value("Saved", point.sample.estimatedSavedCPUPercent),
                        series: .value("Series", "Saved-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.saved)
                    .lineStyle(StrokeStyle(lineWidth: 1.15, lineJoin: .round))
                    .interpolationMethod(.linear)
                }

                ForEach(chartData.points) { point in
                    if let temperatureChartValue = point.temperatureChartValue {
                        LineMark(
                            x: .value("Time", point.sample.date),
                            y: .value(
                                "CPU Temperature",
                                temperatureChartValue
                            ),
                            series: .value(
                                "Series",
                                "CPU Temperature-\(point.segment)"
                            )
                        )
                        .foregroundStyle(TempraPalette.thermal.opacity(0.94))
                        .lineStyle(StrokeStyle(lineWidth: 1.15, lineJoin: .round))
                        .interpolationMethod(.linear)
                    }
                }

                ForEach(chartData.points) { point in
                    LineMark(
                        x: .value("Time", point.sample.date),
                        y: .value("Total", point.sample.systemCPUPercent),
                        series: .value("Series", "Total-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.primaryText.opacity(0.96))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, lineJoin: .round))
                    .interpolationMethod(.linear)
                }

            }
            .chartLegend(.hidden)
            .chartXScale(
                domain: chartData.chartStartDate...chartData.chartEndDate,
                range: .plotDimension(startPadding: 9, endPadding: 9)
            )
            .chartYScale(domain: 0...chartData.chartCeiling)
            .chartPlotStyle { plotArea in
                plotArea
                    .background(TempraPalette.chartPlotFill)
                    .border(TempraPalette.chartBorder, width: 1)
            }
                .chartXAxis {
                    AxisMarks(values: CPUHistoryAxis.tickDates(
                        for: range,
                        endingAt: chartData.chartEndDate,
                        availableWidth: geometry.size.width
                    )) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(TempraPalette.chartGrid)
                    if let date = value.as(Date.self) {
                        AxisValueLabel(
                            anchor: xAxisLabelAnchor(
                                index: value.index,
                                count: value.count
                            ),
                            collisionResolution: .disabled
                        ) {
                            Text(CPUHistoryAxis.label(
                                for: date,
                                range: range,
                                relativeTo: chartData.chartEndDate
                                ))
                                .font(.system(size: 8.75, weight: .regular).monospacedDigit())
                                .foregroundStyle(TempraPalette.secondaryText)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(TempraPalette.chartGrid)
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text("\(Int(percent))%")
                                .font(.system(size: 8.75, weight: .regular).monospacedDigit())
                                .foregroundStyle(TempraPalette.secondaryText)
                        }
                    }
                }
                AxisMarks(
                    position: .trailing,
                    values: [0, chartData.chartCeiling / 2, chartData.chartCeiling]
                ) { value in
                    AxisValueLabel {
                        if let chartValue = value.as(Double.self) {
                            Text("\(Int(chartData.temperatureValue(forChartValue: chartValue)))°")
                                .font(.system(size: 8.75, weight: .regular).monospacedDigit())
                                .foregroundStyle(TempraPalette.secondaryText)
                        }
                    }
                }
                }
                if chartData.points.count < 2 {
                    Text("History builds while Tempra runs")
                        .font(.system(size: 10))
                        .foregroundStyle(TempraPalette.secondaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 9)
            .padding(.bottom, 7)
        }
        .frame(height: 147)
        .background(TempraPalette.chartFill, in: RoundedRectangle(cornerRadius: 9))
    }

    private func xAxisLabelAnchor(index: Int, count: Int) -> UnitPoint {
        index == count - 1 ? .topTrailing : .top
    }
}
