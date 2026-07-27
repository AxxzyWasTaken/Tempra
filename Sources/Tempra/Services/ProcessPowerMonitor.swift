import Darwin
import Foundation

struct ProcessEnergyCounter: Equatable {
    let processStartTime: UInt64
    let energyNanojoules: UInt64
    let cpuTimeNanoseconds: UInt64

    init(
        processStartTime: UInt64,
        energyNanojoules: UInt64,
        cpuTimeNanoseconds: UInt64 = 0
    ) {
        self.processStartTime = processStartTime
        self.energyNanojoules = energyNanojoules
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
    }
}

struct ProcessPowerGroup: Equatable {
    let identifier: String
    let processIdentifiers: [pid_t]
}

struct ProcessPowerSample: Equatable, Sendable {
    let watts: Double
    let joulesPerCPUSecond: Double?
}

final class ProcessPowerMonitor {
    typealias CounterReader = (pid_t) -> ProcessEnergyCounter?

    private let counterReader: CounterReader
    private(set) var isSupported: Bool
    private var previousCounters: [pid_t: ProcessEnergyCounter] = [:]
    private var previousSampleTime: TimeInterval?
    private var rollingSamples: [String: [Double]] = [:]
    private var rollingEnergyIntensitySamples: [String: [Double]] = [:]

    convenience init() {
        let reader = Self.readSystemCounter
        self.init(
            isSupported: Self.platformSupportsProcessEnergy && reader(getpid()) != nil,
            counterReader: reader
        )
    }

    init(isSupported: Bool, counterReader: @escaping CounterReader) {
        self.isSupported = isSupported
        self.counterReader = counterReader
    }

    func sample(
        groups: [ProcessPowerGroup],
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [String: ProcessPowerSample] {
        guard isSupported else {
            reset()
            return [:]
        }

        let processIdentifiers = Set(groups.flatMap(\.processIdentifiers))
        var currentCounters: [pid_t: ProcessEnergyCounter] = [:]
        for pid in processIdentifiers {
            if let counter = counterReader(pid) {
                currentCounters[pid] = counter
            }
        }

        defer {
            previousCounters = currentCounters
            previousSampleTime = now
            let activeIdentifiers = Set(groups.map(\.identifier))
            rollingSamples = rollingSamples.filter { activeIdentifiers.contains($0.key) }
            rollingEnergyIntensitySamples = rollingEnergyIntensitySamples.filter {
                activeIdentifiers.contains($0.key)
            }
        }

        guard let previousSampleTime else { return [:] }
        let elapsed = now - previousSampleTime
        guard elapsed > 0 else { return [:] }

        var result: [String: ProcessPowerSample] = [:]
        for group in groups {
            var energyDelta: UInt64 = 0
            var cpuTimeDelta: UInt64 = 0
            var hasComparableCounter = false

            for pid in group.processIdentifiers {
                guard let previous = previousCounters[pid],
                      let current = currentCounters[pid],
                      previous.processStartTime == current.processStartTime,
                      current.energyNanojoules >= previous.energyNanojoules else {
                    continue
                }
                hasComparableCounter = true
                energyDelta &+= current.energyNanojoules - previous.energyNanojoules
                if current.cpuTimeNanoseconds >= previous.cpuTimeNanoseconds {
                    cpuTimeDelta &+= current.cpuTimeNanoseconds - previous.cpuTimeNanoseconds
                }
            }

            guard hasComparableCounter else {
                rollingSamples.removeValue(forKey: group.identifier)
                rollingEnergyIntensitySamples.removeValue(forKey: group.identifier)
                continue
            }

            let watts = Double(energyDelta) / elapsed / 1_000_000_000
            var samples = rollingSamples[group.identifier, default: []]
            samples.append(max(0, watts))
            if samples.count > 3 {
                samples.removeFirst(samples.count - 3)
            }
            rollingSamples[group.identifier] = samples

            if cpuTimeDelta >= 10_000_000, energyDelta > 0 {
                let joulesPerCPUSecond = Double(energyDelta) / Double(cpuTimeDelta)
                var intensitySamples = rollingEnergyIntensitySamples[group.identifier, default: []]
                intensitySamples.append(joulesPerCPUSecond)
                if intensitySamples.count > 3 {
                    intensitySamples.removeFirst(intensitySamples.count - 3)
                }
                rollingEnergyIntensitySamples[group.identifier] = intensitySamples
            }

            let intensitySamples = rollingEnergyIntensitySamples[group.identifier] ?? []
            result[group.identifier] = ProcessPowerSample(
                watts: samples.reduce(0, +) / Double(samples.count),
                joulesPerCPUSecond: Self.average(intensitySamples)
            )
        }
        return result
    }

    func reset() {
        previousCounters.removeAll()
        previousSampleTime = nil
        rollingSamples.removeAll()
        rollingEnergyIntensitySamples.removeAll()
    }

    private static var platformSupportsProcessEnergy: Bool {
#if arch(arm64)
        true
#else
        false
#endif
    }

    private static func readSystemCounter(pid: pid_t) -> ProcessEnergyCounter? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        guard result == 0 else { return nil }
        return ProcessEnergyCounter(
            processStartTime: usage.ri_proc_start_abstime,
            energyNanojoules: usage.ri_energy_nj,
            cpuTimeNanoseconds: Self.nanosecondsFromMachTicks(
                usage.ri_user_time &+ usage.ri_system_time
            )
        )
    }

    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        _ = mach_timebase_info(&info)
        return info
    }()

    private static func nanosecondsFromMachTicks(_ ticks: UInt64) -> UInt64 {
        let numerator = UInt64(machTimebase.numer)
        let denominator = UInt64(machTimebase.denom)
        guard denominator > 0 else { return ticks }

        let whole = ticks / denominator
        let remainder = ticks % denominator
        return whole * numerator + (remainder * numerator) / denominator
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

struct PowerSavingsEstimator {
    private struct State {
        var recentUnmanagedEnergyIntensity: [Double] = []
        var frozenEnergyIntensity: Double?
        var wasManaged = false
    }

    private var states: [String: State] = [:]

    mutating func update(
        apps: [ManagedApp],
        savedCPUByIdentifier: [String: Double] = [:]
    ) -> [String: Double] {
        let activeIdentifiers = Set(apps.map(\.bundleIdentifier))
        states = states.filter { activeIdentifiers.contains($0.key) }

        var savings: [String: Double] = [:]
        for app in apps {
            let identifier = app.bundleIdentifier
            var state = states[identifier] ?? State()

            if app.status.isActivelySavingPower {
                if !state.wasManaged {
                    state.frozenEnergyIntensity = Self.average(
                        state.recentUnmanagedEnergyIntensity
                    )
                }
                if state.frozenEnergyIntensity == nil,
                   let energyIntensity = app.cpuEnergyJoulesPerCPUSecond {
                    state.frozenEnergyIntensity = max(0, energyIntensity)
                }
                state.wasManaged = true

                let savedCPU = max(0, savedCPUByIdentifier[identifier] ?? 0)
                if savedCPU > 0,
                   let energyIntensity = state.frozenEnergyIntensity {
                    savings[identifier] = savedCPU / 100 * energyIntensity
                }
            } else {
                state.wasManaged = false
                state.frozenEnergyIntensity = nil
                if let energyIntensity = app.cpuEnergyJoulesPerCPUSecond {
                    state.recentUnmanagedEnergyIntensity.append(max(0, energyIntensity))
                    if state.recentUnmanagedEnergyIntensity.count > 5 {
                        state.recentUnmanagedEnergyIntensity.removeFirst(
                            state.recentUnmanagedEnergyIntensity.count - 5
                        )
                    }
                }
            }

            states[identifier] = state
        }
        return savings
    }

    mutating func reset() {
        states.removeAll()
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

enum PowerMetricFormatter {
    static func text(watts: Double?) -> String {
        guard let watts, watts.isFinite else { return "—" }
        let value = max(0, watts)
        let milliwatts = value * 1_000

        if value == 0 {
            return "≈0 mW"
        }
        if value < 1 {
            if milliwatts < 0.1 {
                return "≈<0.1 mW"
            }
            if milliwatts < 1 {
                return String(format: "≈%.1f mW", milliwatts)
            }
            return String(format: "≈%.0f mW", milliwatts)
        }
        return String(format: "≈%.1f W", value)
    }
}

enum PowerMetricAggregation {
    static func trackedPower(apps: [ManagedApp], isSupported: Bool) -> Double? {
        guard isSupported else { return nil }
        let values = apps.compactMap(\.cpuPowerWatts)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    static func estimatedSavedPower(
        apps: [ManagedApp],
        savingsByIdentifier: [String: Double],
        isSupported: Bool
    ) -> Double? {
        guard isSupported else { return nil }
        let managedIdentifiers = Set(
            apps.lazy
                .filter { $0.status.isActivelySavingPower }
                .map(\.bundleIdentifier)
        )
        guard !managedIdentifiers.isEmpty else { return 0 }
        let values = managedIdentifiers.compactMap { savingsByIdentifier[$0] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}
