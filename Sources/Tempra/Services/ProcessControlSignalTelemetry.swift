import Foundation
import OSLog

enum ProcessControlSignalOperation: String, Equatable, Sendable {
    case stop
    case resume
    case stopPrevented
}

enum ProcessControlSignalReason: String, Equatable, Sendable {
    case applicationActivation
    case backgroundPause
    case cpuLimitPulse
    case criticalFileActivity
    case emergencyRestoration
    case networkActive
    case networkProbeUnavailable
    case obsoleteLimit
    case processReconciliation
    case restoration
    case stopRollback
    case userActivationProbe
}

struct ProcessControlSignalEvent: Equatable, Sendable {
    let date: Date
    let bundleIdentifier: String?
    let operation: ProcessControlSignalOperation
    let reason: ProcessControlSignalReason
    let requested: Set<ProcessIdentity>
    let result: ProcessOperationResult
    let stoppedDurations: [ProcessIdentity: TimeInterval]
}

enum ProcessLimitMeasurementKind: String, Equatable, Sendable {
    case activation
    case deadline
    case observation
    case pulse
    case serviceGap
}

struct ProcessLimitMeasurement: Equatable, Sendable {
    let date: Date
    let bundleIdentifier: String
    let kind: ProcessLimitMeasurementKind
    let requestedLimitPercent: Double?
    let measuredCPUPercent: Double?
    let cpuDeltaNanoseconds: UInt64?
    let wallDuration: TimeInterval?
    let deadlineLateness: TimeInterval?
    let activePulseCount: Int
    let serviceGap: TimeInterval?

    var limitErrorPercent: Double? {
        guard let requestedLimitPercent, let measuredCPUPercent else { return nil }
        return measuredCPUPercent - requestedLimitPercent
    }
}

struct ProcessLimitTelemetrySummary: Equatable, Sendable {
    let signalCount: Int
    let maximumActivePulseCount: Int
    let maximumServiceGap: TimeInterval?
    let maximumDeadlineLateness: TimeInterval?
    let peakCPUPercentByWindow: [TimeInterval: Double]
}

actor ProcessControlSignalTelemetry {
    private let logger = Logger(
        subsystem: "io.github.temperapp.Temper",
        category: "ProcessSignals"
    )
    private let capacity: Int
    private var storage: [ProcessControlSignalEvent?]
    private var measurementStorage: [ProcessLimitMeasurement?]
    private var nextIndex = 0
    private var eventCount = 0
    private var nextMeasurementIndex = 0
    private var measurementCount = 0

    init(capacity: Int = 4_096) {
        let boundedCapacity = max(1, capacity)
        self.capacity = boundedCapacity
        storage = Array(repeating: nil, count: boundedCapacity)
        measurementStorage = Array(repeating: nil, count: boundedCapacity)
    }

    func record(_ event: ProcessControlSignalEvent) {
        storage[nextIndex] = event
        nextIndex = (nextIndex + 1) % capacity
        eventCount = min(capacity, eventCount + 1)

        let identifier = event.bundleIdentifier ?? "multiple-apps"
        logger.debug(
            "Process signal \(event.operation.rawValue, privacy: .public) for \(identifier, privacy: .public); reason=\(event.reason.rawValue, privacy: .public), requested=\(event.requested.count), applied=\(event.result.applied.count), stale=\(event.result.stale.count), failed=\(event.result.failed.count)"
        )
    }

    func snapshot() -> [ProcessControlSignalEvent] {
        guard eventCount > 0 else { return [] }
        let startIndex = (nextIndex - eventCount + capacity) % capacity
        return (0..<eventCount).compactMap { offset in
            storage[(startIndex + offset) % capacity]
        }
    }

    func recordMeasurement(_ measurement: ProcessLimitMeasurement) {
        measurementStorage[nextMeasurementIndex] = measurement
        nextMeasurementIndex = (nextMeasurementIndex + 1) % capacity
        measurementCount = min(capacity, measurementCount + 1)
    }

    func measurementSnapshot() -> [ProcessLimitMeasurement] {
        guard measurementCount > 0 else { return [] }
        let startIndex = (nextMeasurementIndex - measurementCount + capacity) % capacity
        return (0..<measurementCount).compactMap { offset in
            measurementStorage[(startIndex + offset) % capacity]
        }
    }

    func summary(
        since startDate: Date,
        cpuWindows: [TimeInterval] = [0.05, 0.1]
    ) -> ProcessLimitTelemetrySummary {
        let signals = snapshot().filter { $0.date >= startDate }
        let measurements = measurementSnapshot().filter { $0.date >= startDate }
        let windows = Set(cpuWindows.filter { $0.isFinite && $0 > 0 }).sorted()
        var peaks: [TimeInterval: Double] = [:]
        let pulses = measurements.filter {
            $0.kind == .pulse && $0.cpuDeltaNanoseconds != nil
        }.sorted { $0.date < $1.date }

        for window in windows {
            var peak = 0.0
            var firstIncludedIndex = 0
            var consumedNanoseconds = 0.0
            for (index, pulse) in pulses.enumerated() {
                consumedNanoseconds += Double(pulse.cpuDeltaNanoseconds ?? 0)
                let windowStart = pulse.date.addingTimeInterval(-window)
                while firstIncludedIndex <= index,
                      pulses[firstIncludedIndex].date < windowStart {
                    consumedNanoseconds -= Double(
                        pulses[firstIncludedIndex].cpuDeltaNanoseconds ?? 0
                    )
                    firstIncludedIndex += 1
                }
                let percent = consumedNanoseconds / (window * 1_000_000_000) * 100
                peak = max(peak, percent)
            }
            peaks[window] = peak
        }

        return ProcessLimitTelemetrySummary(
            signalCount: signals.count,
            maximumActivePulseCount: measurements.map(\.activePulseCount).max() ?? 0,
            maximumServiceGap: measurements.compactMap(\.serviceGap).max(),
            maximumDeadlineLateness: measurements.compactMap(\.deadlineLateness).max(),
            peakCPUPercentByWindow: peaks
        )
    }
}
