import Charts
import SwiftUI

struct AppCPUHistoryChartData {
    struct Point: Identifiable, Equatable {
        let sample: AppCPUHistorySample
        let segment: Int

        var id: Date { sample.date }
    }

    let startDate: Date
    let endDate: Date
    let points: [Point]
    let ceiling: Double

    init(
        samples: [AppCPUHistorySample],
        range: CPUHistoryRange,
        endDate: Date
    ) {
        let resolvedEndDate = endDate
        let resolvedStartDate = endDate.addingTimeInterval(-range.duration)
        self.endDate = resolvedEndDate
        startDate = resolvedStartDate

        let filtered = samples
            .filter {
                $0.date >= resolvedStartDate && $0.date <= resolvedEndDate
            }
            .sorted { $0.date < $1.date }
        let visibleSamples: [AppCPUHistorySample]
        if filtered.count > 180 {
            let step = max(1, (filtered.count + 179) / 180)
            visibleSamples = filtered.enumerated().compactMap { index, sample in
                if index.isMultiple(of: step) || index == filtered.count - 1 {
                    return sample
                }
                return nil
            }
        } else {
            visibleSamples = filtered
        }

        let gapLimit = max(90, range.duration / 120)
        var segment = 0
        var previousDate: Date?
        points = visibleSamples.map { sample in
            if let previousDate,
               sample.date.timeIntervalSince(previousDate) > gapLimit {
                segment += 1
            }
            previousDate = sample.date
            return Point(sample: sample, segment: segment)
        }

        let peak = visibleSamples.reduce(0.0) { currentPeak, sample in
            max(
                currentPeak,
                sample.cpuPercent,
                sample.estimatedSavedCPUPercent
            )
        }
        ceiling = max(25, ceil(peak / 25) * 25)
    }
}

struct AppCPUHistoryChartView: View {
    let samples: [AppCPUHistorySample]
    let range: CPUHistoryRange

    var body: some View {
        let data = AppCPUHistoryChartData(
            samples: samples,
            range: range,
            endDate: Date()
        )

        ZStack {
            Chart {
                ForEach(data.points) { point in
                    AreaMark(
                        x: .value("Time", point.sample.date),
                        yStart: .value("CPU start", 0),
                        yEnd: .value("CPU", point.sample.cpuPercent),
                        series: .value("Series", "CPU-\(point.segment)")
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

                ForEach(data.points) { point in
                    LineMark(
                        x: .value("Time", point.sample.date),
                        y: .value("CPU", point.sample.cpuPercent),
                        series: .value("Series", "CPU-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.performance.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1.0, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }

                ForEach(data.points) { point in
                    LineMark(
                        x: .value("Time", point.sample.date),
                        y: .value(
                            "Estimated CPU saved",
                            point.sample.estimatedSavedCPUPercent
                        ),
                        series: .value("Series", "Saved-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.saved.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round, dash: [3, 3]))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: data.startDate...data.endDate)
            .chartYScale(domain: 0...data.ceiling)
            .chartPlotStyle { plotArea in
                plotArea
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 2)) { value in
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(date, format: .dateTime.hour().minute())
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

            if data.points.count < 2 {
                VStack(spacing: 4) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(TempraPalette.tertiaryText)
                    Text("Collecting app CPU history…")
                        .font(TempraTypography.ruleTag)
                        .foregroundStyle(TempraPalette.secondaryText)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(height: 116)
        .background(
            TempraPalette.chartFill,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TempraPalette.border.opacity(0.4), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Application CPU history for \(range.menuTitle.lowercased())")
    }
}
