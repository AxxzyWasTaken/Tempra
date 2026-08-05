import Foundation
import IOKit
import IOKit.ps

enum BatteryElectricalReading: Equatable, Sendable {
    case discharging(voltageMillivolts: Int64, amperageMilliamps: Int64)
    case externalPower
}

enum BatteryPowerState: Equatable, Sendable {
    case discharging(watts: Double)
    case externalPower
}

final class BatteryPowerMonitor {
    typealias ReadingProvider = () -> BatteryElectricalReading?

    private let readingProvider: ReadingProvider
    private var recentWatts: [Double] = []

    convenience init() {
        self.init(readingProvider: Self.readBattery)
    }

    init(readingProvider: @escaping ReadingProvider) {
        self.readingProvider = readingProvider
    }

    func sample() -> BatteryPowerState? {
        guard let reading = readingProvider() else {
            recentWatts.removeAll(keepingCapacity: true)
            return nil
        }

        let voltageMillivolts: Int64
        let amperageMilliamps: Int64
        switch reading {
        case .externalPower:
            recentWatts.removeAll(keepingCapacity: true)
            return .externalPower
        case .discharging(let voltage, let amperage):
            voltageMillivolts = voltage
            amperageMilliamps = amperage
        }

        guard voltageMillivolts > 0,
              amperageMilliamps < 0,
              amperageMilliamps > Int64.min else {
            recentWatts.removeAll(keepingCapacity: true)
            return nil
        }

        let watts = Double(voltageMillivolts)
            * Double(-amperageMilliamps)
            / 1_000_000
        guard watts.isFinite, watts >= 0 else {
            recentWatts.removeAll(keepingCapacity: true)
            return nil
        }
        recentWatts.append(watts)
        if recentWatts.count > 3 {
            recentWatts.removeFirst(recentWatts.count - 3)
        }
        return .discharging(watts: recentWatts.reduce(0, +) / Double(recentWatts.count))
    }

    private static func readBattery() -> BatteryElectricalReading? {
        guard let infoReference = IOPSCopyPowerSourcesInfo() else { return nil }
        let info = infoReference.takeRetainedValue()
        guard let sourcesReference = IOPSCopyPowerSourcesList(info) else { return nil }
        let sources = sourcesReference.takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let descriptionReference = IOPSGetPowerSourceDescription(info, source),
                  let description = descriptionReference.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let powerSourceState = description[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            if powerSourceState == kIOPSACPowerValue {
                return .externalPower
            }
            guard powerSourceState == kIOPSBatteryPowerValue,
                  let amperage = (description[kIOPSCurrentKey] as? NSNumber)?.int64Value,
                  let voltage = readBatteryVoltage() else {
                return nil
            }
            return .discharging(
                voltageMillivolts: voltage,
                amperageMilliamps: amperage
            )
        }
        return nil
    }

    private static func readBatteryVoltage() -> Int64? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        return integerProperty(kIOPSVoltageKey, service: service)
    }

    private static func integerProperty(
        _ key: String,
        service: io_service_t
    ) -> Int64? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return property.int64Value
    }
}

struct BatteryPowerComparison: Equatable, Sendable {
    var currentWatts: Double?
    var beforeLimitWatts: Double?
    var afterLimitWatts: Double?
    var phase: BatteryPowerMeasurementPhase = .unavailable

    var savedWatts: Double? {
        guard phase == .complete,
              let beforeLimitWatts,
              let afterLimitWatts else { return nil }
        return beforeLimitWatts - afterLimitWatts
    }
}

enum BatteryPowerMeasurementPhase: Equatable, Sendable {
    case unavailable
    case collectingBaseline
    case baselineReady
    case settling
    case measuringAfter
    case complete
    case inconclusive
}

struct BatteryPowerSavingsTracker {
    private struct TimedSample: Equatable, Sendable {
        let watts: Double
        let date: Date
    }

    private struct SampleSummary {
        let watts: Double
        let isStable: Bool
    }

    private let baselineSampleLimit = 12
    private let afterSampleLimit = 12
    private let minimumBaselineSampleCount = 6
    private let minimumAfterSampleCount = 6
    private let minimumWindowDuration: TimeInterval = 9
    private let smoothingFlushSampleCount = 3
    private let maximumSampleAge: TimeInterval = 30
    private let maximumSampleGap: TimeInterval = 30
    private let maximumRelativeStandardDeviation = 0.12
    private let minimumStandardDeviationAllowance = 0.75

    private var beforeSamples: [TimedSample] = []
    private var afterSamples: [TimedSample] = []
    private var activeLimitIdentifiers: Set<String> = []
    private var smoothingSamplesRemaining = 0
    private var measurementIsInvalid = false
    private var lastSampleDate: Date?
    private(set) var comparison = BatteryPowerComparison()

    mutating func update(
        state: BatteryPowerState?,
        activeLimitIdentifiers newActiveLimitIdentifiers: Set<String>,
        now: Date = Date()
    ) {
        guard case .discharging(let watts) = state,
              watts.isFinite,
              watts >= 0 else {
            reset()
            return
        }

        if let lastSampleDate {
            let gap = now.timeIntervalSince(lastSampleDate)
            if gap < 0 || gap > maximumSampleGap {
                reset()
            }
        }
        lastSampleDate = now
        comparison.currentWatts = watts

        if newActiveLimitIdentifiers.isEmpty {
            updateBaseline(watts: watts, now: now)
            activeLimitIdentifiers = []
            return
        }

        if activeLimitIdentifiers.isEmpty {
            beginMeasurement()
        } else if newActiveLimitIdentifiers != activeLimitIdentifiers {
            invalidateMeasurement()
        }
        activeLimitIdentifiers = newActiveLimitIdentifiers

        guard !measurementIsInvalid,
              comparison.phase != .complete else { return }

        if smoothingSamplesRemaining > 0 {
            smoothingSamplesRemaining -= 1
            comparison.phase = .settling
            return
        }

        append(
            TimedSample(watts: watts, date: now),
            to: &afterSamples,
            limit: afterSampleLimit,
            now: now
        )
        guard hasEnoughSamples(
            afterSamples,
            minimumCount: minimumAfterSampleCount
        ) else {
            comparison.phase = .measuringAfter
            return
        }

        let summary = summarize(afterSamples)
        guard summary.isStable else {
            invalidateMeasurement()
            return
        }
        comparison.afterLimitWatts = summary.watts
        comparison.phase = .complete
    }

    mutating func reset() {
        beforeSamples.removeAll(keepingCapacity: true)
        afterSamples.removeAll(keepingCapacity: true)
        activeLimitIdentifiers.removeAll(keepingCapacity: true)
        smoothingSamplesRemaining = 0
        measurementIsInvalid = false
        lastSampleDate = nil
        comparison = BatteryPowerComparison()
    }

    private mutating func updateBaseline(watts: Double, now: Date) {
        if !activeLimitIdentifiers.isEmpty {
            beforeSamples.removeAll(keepingCapacity: true)
            afterSamples.removeAll(keepingCapacity: true)
            smoothingSamplesRemaining = smoothingFlushSampleCount
            measurementIsInvalid = false
            comparison.beforeLimitWatts = nil
            comparison.afterLimitWatts = nil
        }

        guard smoothingSamplesRemaining == 0 else {
            smoothingSamplesRemaining -= 1
            comparison.phase = .collectingBaseline
            return
        }

        append(
            TimedSample(watts: watts, date: now),
            to: &beforeSamples,
            limit: baselineSampleLimit,
            now: now
        )
        guard hasEnoughSamples(
            beforeSamples,
            minimumCount: minimumBaselineSampleCount
        ) else {
            comparison.beforeLimitWatts = nil
            comparison.phase = .collectingBaseline
            return
        }

        let summary = summarize(beforeSamples)
        comparison.beforeLimitWatts = summary.isStable ? summary.watts : nil
        comparison.afterLimitWatts = nil
        comparison.phase = summary.isStable ? .baselineReady : .collectingBaseline
    }

    private mutating func beginMeasurement() {
        afterSamples.removeAll(keepingCapacity: true)
        smoothingSamplesRemaining = smoothingFlushSampleCount
        let baseline = summarize(beforeSamples)
        guard hasEnoughSamples(
            beforeSamples,
            minimumCount: minimumBaselineSampleCount
        ),
              baseline.isStable else {
            comparison.beforeLimitWatts = nil
            comparison.afterLimitWatts = nil
            comparison.phase = .inconclusive
            measurementIsInvalid = true
            return
        }
        comparison.beforeLimitWatts = baseline.watts
        comparison.afterLimitWatts = nil
        comparison.phase = .settling
        measurementIsInvalid = false
    }

    private mutating func invalidateMeasurement() {
        afterSamples.removeAll(keepingCapacity: true)
        comparison.afterLimitWatts = nil
        comparison.phase = .inconclusive
        measurementIsInvalid = true
    }

    private func append(
        _ sample: TimedSample,
        to samples: inout [TimedSample],
        limit: Int,
        now: Date
    ) {
        samples.append(sample)
        let cutoff = now.addingTimeInterval(-maximumSampleAge)
        samples.removeAll { $0.date < cutoff }
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }
    }

    private func summarize(_ samples: [TimedSample]) -> SampleSummary {
        guard !samples.isEmpty else {
            return SampleSummary(watts: 0, isStable: false)
        }
        let sortedWatts = samples.map(\.watts).sorted()
        let trimCount = sortedWatts.count >= minimumBaselineSampleCount ? 1 : 0
        let upperBound = sortedWatts.count - trimCount
        let trimmedWatts = Array(sortedWatts[trimCount..<upperBound])
        let mean = trimmedWatts.reduce(0, +) / Double(trimmedWatts.count)
        let variance = trimmedWatts.reduce(0) { result, watts in
            let difference = watts - mean
            return result + difference * difference
        } / Double(trimmedWatts.count)
        let standardDeviation = variance.squareRoot()
        let allowedStandardDeviation = max(
            minimumStandardDeviationAllowance,
            mean * maximumRelativeStandardDeviation
        )
        return SampleSummary(
            watts: mean,
            isStable: standardDeviation <= allowedStandardDeviation
        )
    }

    private func hasEnoughSamples(
        _ samples: [TimedSample],
        minimumCount: Int
    ) -> Bool {
        guard samples.count >= minimumCount,
              let firstDate = samples.first?.date,
              let lastDate = samples.last?.date else { return false }
        return lastDate.timeIntervalSince(firstDate) >= minimumWindowDuration
    }
}

enum BatteryPowerFormatter {
    static func text(watts: Double?) -> String {
        guard let watts, watts.isFinite, watts >= 0 else { return "—" }
        if watts < 1 {
            return String(format: "%.0f mW", watts * 1_000)
        }
        return String(format: "%.1f W", watts)
    }

    static func savingsText(watts: Double?) -> String {
        guard let watts, watts.isFinite else { return "—" }
        if abs(watts) < 0.05 { return "No change" }
        let amount = String(format: "%.1f W", abs(watts))
        return watts > 0 ? "\(amount) less" : "\(amount) more"
    }

    static func beforeLimitText(_ comparison: BatteryPowerComparison) -> String {
        switch comparison.phase {
        case .unavailable:
            "—"
        case .collectingBaseline:
            "Measuring…"
        case .inconclusive where comparison.beforeLimitWatts == nil:
            "Inconclusive"
        case .baselineReady, .settling, .measuringAfter, .complete, .inconclusive:
            text(watts: comparison.beforeLimitWatts)
        }
    }

    static func afterLimitText(_ comparison: BatteryPowerComparison) -> String {
        switch comparison.phase {
        case .unavailable:
            "—"
        case .collectingBaseline, .baselineReady:
            "Waiting"
        case .settling:
            "Settling…"
        case .measuringAfter:
            "Measuring…"
        case .complete:
            text(watts: comparison.afterLimitWatts)
        case .inconclusive:
            "Inconclusive"
        }
    }

    static func changeText(_ comparison: BatteryPowerComparison) -> String {
        switch comparison.phase {
        case .unavailable:
            "—"
        case .collectingBaseline, .baselineReady:
            "Waiting"
        case .settling, .measuringAfter:
            "Measuring…"
        case .complete:
            savingsText(watts: comparison.savedWatts)
        case .inconclusive:
            "Inconclusive"
        }
    }
}
