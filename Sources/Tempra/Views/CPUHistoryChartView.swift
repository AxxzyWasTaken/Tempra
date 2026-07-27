import Charts
import SwiftUI

struct CPUHistoryChartView: View {
    private struct ChartPoint: Identifiable {
        let sample: CPUHistorySample
        let segment: Int

        var id: Date { sample.date }
    }

    let samples: [CPUHistorySample]
    @Binding var range: CPUHistoryRange
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int

    var body: some View {
        let chartEndDate = now
        let chartStartDate = chartEndDate.addingTimeInterval(-range.duration)

        GeometryReader { geometry in
            ZStack {
                Chart {
                ForEach(chartPoints) { point in
                    AreaMark(
                        x: .value("Time", point.sample.date),
                        yStart: .value("Efficiency Start", 0),
                        yEnd: .value("Efficiency", point.sample.efficiencyCPUPercent),
                        series: .value("Series", "Efficiency-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.efficiencyArea)
                    .interpolationMethod(.linear)
                }

                ForEach(chartPoints) { point in
                    AreaMark(
                        x: .value("Time", point.sample.date),
                        yStart: .value(
                            "Performance Start",
                            point.sample.efficiencyCPUPercent
                        ),
                        yEnd: .value(
                            "Performance",
                            combinedContribution(for: point.sample)
                        ),
                        series: .value("Series", "Performance-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.performanceArea)
                    .interpolationMethod(.linear)
                }

                ForEach(chartPoints) { point in
                    LineMark(
                        x: .value("Time", point.sample.date),
                        y: .value("Efficiency Boundary", point.sample.efficiencyCPUPercent),
                        series: .value("Series", "Efficiency Boundary-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.efficiency.opacity(0.80))
                    .lineStyle(StrokeStyle(lineWidth: 0.65, lineJoin: .round))
                    .interpolationMethod(.linear)
                }

                ForEach(chartPoints) { point in
                    LineMark(
                        x: .value("Time", point.sample.date),
                        y: .value("Saved", point.sample.estimatedSavedCPUPercent),
                        series: .value("Series", "Saved-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.saved)
                    .lineStyle(StrokeStyle(lineWidth: 1.15, lineJoin: .round))
                    .interpolationMethod(.linear)
                }

                ForEach(chartPoints) { point in
                    if let temperature = point.sample.cpuTemperatureCelsius {
                        LineMark(
                            x: .value("Time", point.sample.date),
                            y: .value(
                                "CPU Temperature",
                                chartValue(forTemperature: temperature)
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

                ForEach(chartPoints) { point in
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
                domain: chartStartDate...chartEndDate,
                range: .plotDimension(startPadding: 9, endPadding: 9)
            )
            .chartYScale(domain: 0...chartCeiling)
            .chartPlotStyle { plotArea in
                plotArea
                    .background(TempraPalette.chartPlotFill)
                    .border(TempraPalette.chartBorder, width: 1)
            }
                .chartXAxis {
                    AxisMarks(values: CPUHistoryAxis.tickDates(
                        for: range,
                        endingAt: chartEndDate,
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
                                relativeTo: chartEndDate
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
                    values: [0, chartCeiling / 2, chartCeiling]
                ) { value in
                    AxisValueLabel {
                        if let chartValue = value.as(Double.self) {
                            Text("\(Int(temperatureValue(forChartValue: chartValue)))°")
                                .font(.system(size: 8.75, weight: .regular).monospacedDigit())
                                .foregroundStyle(TempraPalette.secondaryText)
                        }
                    }
                }
                }
                if visibleSamples.count < 2 {
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

    private var now: Date { Date() }
    private var cutoffDate: Date { now.addingTimeInterval(-range.duration) }

    private var visibleSamples: [CPUHistorySample] {
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

    private var chartPoints: [ChartPoint] {
        var segment = 0
        var previousDate: Date?
        let gapLimit = max(45, range.duration / 120)

        return visibleSamples.map { sample in
            if let previousDate,
               sample.date.timeIntervalSince(previousDate) > gapLimit {
                segment += 1
            }
            previousDate = sample.date
            return ChartPoint(sample: sample, segment: segment)
        }
    }

    private var chartCeiling: Double {
        let peak = visibleSamples.reduce(0.0) { result, sample in
            max(
                result,
                sample.systemCPUPercent,
                combinedContribution(for: sample),
                sample.estimatedSavedCPUPercent
            )
        }
        if peak <= 40 { return 40 }
        if peak <= 60 { return 60 }
        if peak <= 80 { return 80 }
        return 100
    }

    private func combinedContribution(for sample: CPUHistorySample) -> Double {
        sample.efficiencyCPUPercent + sample.performanceCPUPercent
    }

    private func xAxisLabelAnchor(index: Int, count: Int) -> UnitPoint {
        index == count - 1 ? .topTrailing : .top
    }

    private var temperatureCeiling: Double {
        let peak = visibleSamples.compactMap(\.cpuTemperatureCelsius).max() ?? 60
        guard peak > 60 else { return 60 }
        return ceil(peak / 15) * 15
    }

    private var temperatureFloor: Double {
        temperatureCeiling - 30
    }

    private func chartValue(forTemperature temperature: Double) -> Double {
        let fraction = (temperature - temperatureFloor) / 30
        return min(chartCeiling, max(0, fraction * chartCeiling))
    }

    private func temperatureValue(forChartValue value: Double) -> Double {
        temperatureFloor + value / chartCeiling * 30
    }

}
