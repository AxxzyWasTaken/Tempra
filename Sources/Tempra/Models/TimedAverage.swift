import Foundation

struct TimedAverage {
    private struct Sample {
        let date: Date
        let value: Double
    }

    private var samples: [Sample] = []

    var value: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0) { $0 + $1.value } / Double(samples.count)
    }

    mutating func add(_ value: Double, at date: Date, window: TimeInterval) {
        samples.append(Sample(date: date, value: value))
        let cutoff = date.addingTimeInterval(-window)
        samples.removeAll { $0.date < cutoff }
    }
}
