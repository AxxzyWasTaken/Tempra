import Charts
import SwiftUI

struct CPUHistoryChartData {
    struct Point: Identifiable, Equatable {
        let sample: CPUHistorySample
        let segment: Int
        let savedCPUSegment: Int?
        let temperatureSegment: Int?
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
        let downsamplingStep: Int?
        let visibleSamples: [CPUHistorySample]
        if range == .day, filteredSamples.count > 320 {
            let step = max(1, filteredSamples.count / 320)
            downsamplingStep = step
            visibleSamples = filteredSamples.enumerated().compactMap { index, sample in
                if index.isMultiple(of: step) || index == filteredSamples.count - 1 {
                    return sample
                }
                return nil
            }
        } else {
            downsamplingStep = nil
            visibleSamples = filteredSamples
        }

        let cpuPeak = visibleSamples.reduce(0.0) { result, sample in
            max(
                result,
                sample.systemCPUPercent,
                sample.efficiencyCPUPercent + sample.performanceCPUPercent,
                sample.hasEstimatedSavedCPUMeasurement
                    ? sample.estimatedSavedCPUPercent
                    : 0
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
        var savedCPUSegment = 0
        var previousSavedCPUDate: Date?
        var temperatureSegment = 0
        var previousTemperatureDate: Date?
        let gapLimit = max(45, range.duration / 120)
        points = filteredSamples.enumerated().compactMap { index, sample in
            if let previousDate,
               sample.date.timeIntervalSince(previousDate) > gapLimit {
                segment += 1
            }
            previousDate = sample.date

            let resolvedSavedCPUSegment: Int?
            if sample.hasEstimatedSavedCPUMeasurement {
                if let previousSavedCPUDate {
                    if sample.date.timeIntervalSince(previousSavedCPUDate) > gapLimit {
                        savedCPUSegment += 1
                    }
                } else {
                    savedCPUSegment += 1
                }
                previousSavedCPUDate = sample.date
                resolvedSavedCPUSegment = savedCPUSegment
            } else {
                previousSavedCPUDate = nil
                resolvedSavedCPUSegment = nil
            }

            let resolvedTemperatureSegment: Int?
            if sample.cpuTemperatureCelsius != nil {
                if let previousTemperatureDate {
                    if sample.date.timeIntervalSince(previousTemperatureDate) > gapLimit {
                        temperatureSegment += 1
                    }
                } else {
                    temperatureSegment += 1
                }
                previousTemperatureDate = sample.date
                resolvedTemperatureSegment = temperatureSegment
            } else {
                previousTemperatureDate = nil
                resolvedTemperatureSegment = nil
            }

            if let downsamplingStep,
               !index.isMultiple(of: downsamplingStep),
               index != filteredSamples.count - 1 {
                return nil
            }

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
                savedCPUSegment: resolvedSavedCPUSegment,
                temperatureSegment: resolvedTemperatureSegment,
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
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    TempraPalette.efficiency.opacity(0.38),
                                    TempraPalette.efficiency.opacity(0.06)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
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
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    TempraPalette.performance.opacity(0.44),
                                    TempraPalette.performance.opacity(0.08)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }

                    ForEach(chartData.points) { point in
                        LineMark(
                            x: .value("Time", point.sample.date),
                            y: .value("Efficiency Boundary", point.sample.efficiencyCPUPercent),
                            series: .value("Series", "Efficiency Boundary-\(point.segment)")
                        )
                        .foregroundStyle(TempraPalette.efficiency.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 0.65, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                    }

                    ForEach(chartData.points) { point in
                        if point.sample.hasEstimatedSavedCPUMeasurement,
                           let savedCPUSegment = point.savedCPUSegment {
                            LineMark(
                                x: .value("Time", point.sample.date),
                                y: .value("Saved", point.sample.estimatedSavedCPUPercent),
                                series: .value("Series", "Saved-\(savedCPUSegment)")
                            )
                            .foregroundStyle(TempraPalette.saved.opacity(0.85))
                            .lineStyle(StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round, dash: [3, 3]))
                            .interpolationMethod(.catmullRom)
                        }
                    }

                    ForEach(chartData.points) { point in
                        if let temperatureChartValue = point.temperatureChartValue,
                           let temperatureSegment = point.temperatureSegment {
                            LineMark(
                                x: .value("Time", point.sample.date),
                                y: .value(
                                    "CPU Temperature",
                                    temperatureChartValue
                                ),
                                series: .value(
                                    "Series",
                                    "CPU Temperature-\(temperatureSegment)"
                                )
                            )
                            .foregroundStyle(TempraPalette.thermal.opacity(0.85))
                            .lineStyle(StrokeStyle(lineWidth: 1.0, lineJoin: .round))
                            .interpolationMethod(.catmullRom)
                        }
                    }

                    ForEach(chartData.points) { point in
                        LineMark(
                            x: .value("Time", point.sample.date),
                            y: .value("Total", point.sample.systemCPUPercent),
                            series: .value("Series", "Total-\(point.segment)")
                        )
                        .foregroundStyle(TempraPalette.primaryText.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1.0, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartLegend(.hidden)
                .chartXScale(
                    domain: chartData.chartStartDate...chartData.chartEndDate,
                    range: .plotDimension(startPadding: 6, endPadding: 6)
                )
                .chartYScale(domain: 0...chartData.chartCeiling)
                .chartPlotStyle { plotArea in
                    plotArea
                }
                .chartXAxis {
                    AxisMarks(values: CPUHistoryAxis.tickDates(
                        for: range,
                        endingAt: chartData.chartEndDate,
                        availableWidth: geometry.size.width
                    )) { value in
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
                                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(TempraPalette.tertiaryText)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(TempraPalette.chartGrid.opacity(0.6))
                        AxisValueLabel {
                            if let percent = value.as(Double.self) {
                                Text("\(Int(percent))%")
                                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                                    .foregroundStyle(TempraPalette.tertiaryText)
                            }
                        }
                    }
                }

                if chartData.points.count < 2 {
                    VStack(spacing: 4) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(TempraPalette.tertiaryText)
                        Text("Collecting CPU history…")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TempraPalette.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .frame(height: 128)
        .background(TempraPalette.chartFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TempraPalette.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func xAxisLabelAnchor(index: Int, count: Int) -> UnitPoint {
        index == count - 1 ? .topTrailing : .top
    }
}
