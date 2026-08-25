import Foundation

/// The visible slice of one app's history for a chart.
///
/// Charts of app history share three concerns: clip to the selected range, thin
/// dense histories down to something a small plot can draw, and break the line
/// where sampling stopped. Both the CPU chart and the GPU power strip read the
/// same window so their x axes always agree.
struct AppHistoryWindow {
    /// A sample together with the run of uninterrupted sampling it belongs to.
    struct Point: Identifiable, Equatable {
        let sample: AppCPUHistorySample
        let segment: Int

        var id: Date { sample.date }
    }

    /// The most points a chart this size can resolve. Beyond it the line is
    /// drawing pixels twice.
    private static let maximumPoints = 180

    let startDate: Date
    let endDate: Date
    let points: [Point]

    init(
        samples: [AppCPUHistorySample],
        range: CPUHistoryRange,
        endDate: Date
    ) {
        self.endDate = endDate
        startDate = endDate.addingTimeInterval(-range.duration)

        let start = startDate
        let end = endDate
        let filtered = samples
            .filter { $0.date >= start && $0.date <= end }
            .sorted { $0.date < $1.date }

        let visibleSamples: [AppCPUHistorySample]
        if filtered.count > Self.maximumPoints {
            let step = max(1, (filtered.count + Self.maximumPoints - 1) / Self.maximumPoints)
            visibleSamples = filtered.enumerated().compactMap { index, sample in
                index.isMultiple(of: step) || index == filtered.count - 1 ? sample : nil
            }
        } else {
            visibleSamples = filtered
        }

        // A pause longer than this is missing history, not a flat line.
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
    }

    /// The highest value any visible sample reports for `metric`.
    func peak(of metric: (AppCPUHistorySample) -> Double) -> Double {
        points.reduce(0) { max($0, metric($1.sample)) }
    }
}
