import Charts
import SwiftUI

struct AppCPUHistoryChartData {
    typealias Point = AppHistoryWindow.Point

    let startDate: Date
    let endDate: Date
    let points: [Point]
    let ceiling: Double

    init(
        samples: [AppCPUHistorySample],
        range: CPUHistoryRange,
        endDate: Date
    ) {
        let window = AppHistoryWindow(
            samples: samples,
            range: range,
            endDate: endDate
        )
        startDate = window.startDate
        self.endDate = window.endDate
        points = window.points

        let peak = max(
            window.peak(of: \.cpuPercent),
            window.peak(of: \.estimatedSavedCPUPercent)
        )
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
