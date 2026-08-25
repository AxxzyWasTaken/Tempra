import Charts
import SwiftUI

/// The GPU power an app drew over the selected range, and the ceiling its rule
/// enforces.
///
/// A watt ceiling is only choosable against what the app actually draws: the
/// instantaneous number swings with the GPU's clocks, so the peak over a window
/// is what says whether a ceiling will ever act.
struct AppGPUPowerChartData {
    typealias Point = AppHistoryWindow.Point

    let startDate: Date
    let endDate: Date
    let points: [Point]
    let peakWatts: Double
    let ceiling: Double
    /// Whether the range holds any GPU work at all. A flat line at zero says
    /// nothing; the strip says so in words instead.
    let hasGPUWork: Bool

    init(
        samples: [AppCPUHistorySample],
        range: CPUHistoryRange,
        endDate: Date,
        limitWatts: Double? = nil
    ) {
        let window = AppHistoryWindow(
            samples: samples,
            range: range,
            endDate: endDate
        )
        startDate = window.startDate
        self.endDate = window.endDate
        points = window.points
        peakWatts = window.peak(of: \.gpuWatts)
        hasGPUWork = peakWatts > 0.05
        ceiling = Self.ceiling(peakWatts: peakWatts, limitWatts: limitWatts)
    }

    /// Keeps both the curve and the limit line inside the plot, and never
    /// collapses to a scale that magnifies noise on an idle GPU.
    private static func ceiling(peakWatts: Double, limitWatts: Double?) -> Double {
        let headroom = max(peakWatts, limitWatts ?? 0) * 1.15
        guard headroom > 1 else { return 1 }
        let step: Double = headroom <= 10 ? 1 : (headroom <= 50 ? 5 : 10)
        return ceil(headroom / step) * step
    }
}

/// A compact strip under the CPU history chart: GPU power over time, its peak,
/// and the rule's ceiling as a threshold line.
struct AppGPUPowerChartView: View {
    let samples: [AppCPUHistorySample]
    let range: CPUHistoryRange
    let limitWatts: Double?

    var body: some View {
        let data = AppGPUPowerChartData(
            samples: samples,
            range: range,
            endDate: Date(),
            limitWatts: limitWatts
        )

        VStack(alignment: .leading, spacing: 5) {
            header(data)
            plot(data)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(data))
    }

    private func header(_ data: AppGPUPowerChartData) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("GPU power")
                .font(TempraTypography.ruleTag)
                .foregroundStyle(TempraPalette.secondaryText)

            Spacer(minLength: 4)

            Text(data.hasGPUWork ? "peak \(wattsText(data.peakWatts))" : "no GPU work")
                .font(TempraTypography.ruleTag.monospacedDigit())
                .foregroundStyle(TempraPalette.primaryText)

            if let limitWatts {
                Text("limit \(wattsText(limitWatts))")
                    .font(TempraTypography.ruleTag.monospacedDigit())
                    .foregroundStyle(TempraPalette.waiting)
            }
        }
    }

    private func plot(_ data: AppGPUPowerChartData) -> some View {
        ZStack {
            Chart {
                ForEach(data.points) { point in
                    AreaMark(
                        x: .value("Time", point.sample.date),
                        yStart: .value("GPU start", 0),
                        yEnd: .value("GPU power", point.sample.gpuWatts),
                        series: .value("Series", "GPU-\(point.segment)")
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                TempraPalette.gpuPower.opacity(0.40),
                                TempraPalette.gpuPower.opacity(0.06)
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
                        y: .value("GPU power", point.sample.gpuWatts),
                        series: .value("Series", "GPU-\(point.segment)")
                    )
                    .foregroundStyle(TempraPalette.gpuPower.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1.0, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }

                if let limitWatts, limitWatts <= data.ceiling {
                    RuleMark(y: .value("GPU limit", limitWatts))
                        .foregroundStyle(TempraPalette.waiting.opacity(0.85))
                        .lineStyle(
                            StrokeStyle(lineWidth: 0.9, lineCap: .round, dash: [3, 3])
                        )
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: data.startDate...data.endDate)
            .chartYScale(domain: 0...data.ceiling)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, data.ceiling]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(TempraPalette.chartGrid.opacity(0.6))
                    AxisValueLabel {
                        if let watts = value.as(Double.self), watts > 0 {
                            Text(wattsText(watts))
                                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(TempraPalette.tertiaryText)
                        }
                    }
                }
            }
            .opacity(data.hasGPUWork ? 1 : 0.35)

            if !data.hasGPUWork {
                Text(idleMessage)
                    .font(TempraTypography.ruleTag)
                    .foregroundStyle(TempraPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(height: 62)
        .background(
            TempraPalette.chartFill,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TempraPalette.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    /// Says why the strip is empty, and what that means for a ceiling.
    private var idleMessage: String {
        limitWatts == nil
            ? "No GPU work recorded in this range."
            : "No GPU work recorded in this range, so the limit stays idle."
    }

    private func wattsText(_ value: Double) -> String {
        value < 10
            ? String(format: "%.1f W", value)
            : String(format: "%.0f W", value)
    }

    private func accessibilityLabel(_ data: AppGPUPowerChartData) -> String {
        guard data.hasGPUWork else {
            return "GPU power over \(range.menuTitle.lowercased()): no GPU work recorded"
        }
        let peak = "GPU power over \(range.menuTitle.lowercased()),"
            + " peak \(wattsText(data.peakWatts))"
        guard let limitWatts else { return peak }
        return "\(peak), limit \(wattsText(limitWatts))"
    }
}
