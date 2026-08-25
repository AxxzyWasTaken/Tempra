import Darwin
import TempraSensors
import Foundation
import IOKit

/// Reads accumulated GPU busy time per process.
///
/// The Apple Silicon GPU driver publishes one user client per process that
/// submits GPU work. Each client carries an `AppUsage` array with one entry per
/// command queue, and each entry reports `accumulatedGPUTime` in nanoseconds of
/// GPU busy time since the queue was created. The values are readable without
/// root. There is no per-process GPU counter in `task_info`; on Apple Silicon
/// `task_power_info_v2.gpu_energy.task_gpu_utilisation` stays at zero.
protocol GPUUsageReading: Sendable {
    /// Accumulated GPU busy nanoseconds for every process with a GPU client.
    func accumulatedBusyNanoseconds() -> [pid_t: UInt64]

    /// Accumulated GPU busy nanoseconds for the requested processes only.
    ///
    /// A process without a reachable GPU client is absent from the result.
    func accumulatedBusyNanoseconds(for pids: Set<pid_t>) -> [pid_t: UInt64]
}

final class LiveGPUUsageReader: GPUUsageReading, @unchecked Sendable {
    /// One reader for the whole app. The registry scan is rate limited inside,
    /// so the process list, the power scale, and the limiter share a single
    /// pass instead of paying for one each.
    static let shared = LiveGPUUsageReader()

    private static let acceleratorClassName = "IOAccelerator"
    private static let userClientClassName = "IOUserClient"
    private static let creatorPropertyName = "IOUserClientCreator"
    private static let usagePropertyName = "AppUsage"
    private static let busyTimeKey = "accumulatedGPUTime"

    private let lock = NSLock()
    private let uptime: () -> TimeInterval
    private let minimumEnumerationInterval: TimeInterval
    private var clientsByPID: [pid_t: [io_object_t]] = [:]
    private var lastEnumerationTime: TimeInterval?

    init(
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        minimumEnumerationInterval: TimeInterval = 1
    ) {
        self.uptime = uptime
        self.minimumEnumerationInterval = minimumEnumerationInterval
    }

    deinit {
        for clients in clientsByPID.values {
            for client in clients {
                IOObjectRelease(client)
            }
        }
    }

    func accumulatedBusyNanoseconds() -> [pid_t: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        // The client set is what the scan is for, and it costs milliseconds to
        // walk. Two readers sample within the same second — the process list and
        // the power scale — so the rate limit holds here too, and the busy
        // counters below are read from the retained clients either way.
        if canEnumerate() {
            refreshClients()
        }
        var totals: [pid_t: UInt64] = [:]
        totals.reserveCapacity(clientsByPID.count)
        for (pid, clients) in clientsByPID {
            totals[pid] = Self.busyNanoseconds(of: clients)
        }
        return totals
    }

    func accumulatedBusyNanoseconds(for pids: Set<pid_t>) -> [pid_t: UInt64] {
        guard !pids.isEmpty else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        if pids.contains(where: { clientsByPID[$0] == nil }), canEnumerate() {
            refreshClients()
        }
        var totals: [pid_t: UInt64] = [:]
        totals.reserveCapacity(pids.count)
        for pid in pids {
            guard let clients = clientsByPID[pid] else { continue }
            totals[pid] = Self.busyNanoseconds(of: clients)
        }
        return totals
    }

    private func canEnumerate() -> Bool {
        guard let lastEnumerationTime else { return true }
        let now = uptime()
        return now < lastEnumerationTime
            || now - lastEnumerationTime >= minimumEnumerationInterval
    }

    private func refreshClients() {
        let discovered = Self.enumerateClients()
        for clients in clientsByPID.values {
            for client in clients {
                IOObjectRelease(client)
            }
        }
        clientsByPID = discovered
        lastEnumerationTime = uptime()
    }

    private static func enumerateClients() -> [pid_t: [io_object_t]] {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(acceleratorClassName),
            &accelerators
        ) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(accelerators) }

        var clientsByPID: [pid_t: [io_object_t]] = [:]
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(
                accelerator,
                kIOServicePlane,
                &children
            ) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(children) }

            while case let child = IOIteratorNext(children), child != 0 {
                guard IOObjectConformsTo(child, userClientClassName) != 0,
                      let pid = processIdentifier(of: child) else {
                    IOObjectRelease(child)
                    continue
                }
                clientsByPID[pid, default: []].append(child)
            }
        }
        return clientsByPID
    }

    /// Parses `"pid 4213, Safari"` into the process identifier.
    static func processIdentifier(fromCreator creator: String) -> pid_t? {
        let prefix = "pid "
        guard creator.hasPrefix(prefix) else { return nil }
        let remainder = creator.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: ",") else { return nil }
        guard let pid = pid_t(remainder[remainder.startIndex..<separator]), pid > 0 else {
            return nil
        }
        return pid
    }

    private static func processIdentifier(of client: io_object_t) -> pid_t? {
        guard let creator = IORegistryEntryCreateCFProperty(
            client,
            creatorPropertyName as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return nil
        }
        return processIdentifier(fromCreator: creator)
    }

    private static func busyNanoseconds(of clients: [io_object_t]) -> UInt64 {
        var total: UInt64 = 0
        for client in clients {
            guard let queues = IORegistryEntryCreateCFProperty(
                client,
                usagePropertyName as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [[String: Any]] else {
                continue
            }
            for queue in queues {
                guard let value = queue[busyTimeKey] as? NSNumber else { continue }
                total = total.addingReportingOverflow(value.uint64Value).partialValue
            }
        }
        return total
    }
}

/// Converts accumulated GPU busy counters into a percentage of one GPU.
///
/// GPU percent is relative to a single device, so the value is capped at 100
/// even when a process spreads work across several command queues that the
/// driver accounts for in parallel.
struct GPUUsageSampler {
    static let maximumPercent: Double = 100

    private var previousCounters: [pid_t: UInt64] = [:]
    private var previousSampleTime: TimeInterval?

    init() {}

    static func percent(busyNanoseconds: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        let percent = Double(busyNanoseconds) / (elapsed * 1_000_000_000) * 100
        guard percent.isFinite else { return 0 }
        return min(maximumPercent, max(0, percent))
    }

    /// Returns the GPU percentage for every process in `counters`.
    ///
    /// A process reports zero on its first sample, and after a counter reset:
    /// the driver drops a client when its process exits, so the accumulated
    /// total for a reused identifier can fall.
    mutating func sample(
        counters: [pid_t: UInt64],
        at uptime: TimeInterval
    ) -> [pid_t: Double] {
        defer {
            previousCounters = counters
            previousSampleTime = uptime
        }
        guard let previousSampleTime, uptime > previousSampleTime else {
            return counters.mapValues { _ in 0 }
        }
        let elapsed = uptime - previousSampleTime
        return counters.mapValues { _ in 0 }.merging(
            counters.compactMap { pid, counter -> (pid_t, Double)? in
                guard let previous = previousCounters[pid], counter >= previous else {
                    return nil
                }
                return (pid, Self.percent(
                    busyNanoseconds: counter - previous,
                    elapsed: elapsed
                ))
            },
            uniquingKeysWith: { _, measured in measured }
        )
    }
}

/// Reads GPU power.
///
/// The number that matches the system power tools is the SoC energy model's GPU
/// counter: it integrates energy, so power is a delta over a measured interval.
/// Measured on an M4 Max: 0.46 W idle and 38.7 W under a saturating compute
/// load, against 34.0 W for the driver's own `FilteredGPUPower` at the same
/// moment. The driver property is a filtered value that lags and, on some
/// workloads, understates badly, so it is only the fallback when the energy
/// counter is unavailable.
///
/// `MaxGPUAbsolutePower` stays the source for the budget: it is the ceiling the
/// firmware currently allows, not a live reading.
protocol GPUPowerReading: Sendable {
    /// GPU power draw in watts, or nil until an interval has been measured.
    ///
    /// The reading is the mean since the previous call on the same instance,
    /// so interleaved callers of a shared reader each measure a shorter — but
    /// still accurate — window.
    func currentWatts() -> Double?

    /// The GPU power budget in watts the firmware allows at this moment.
    func budgetWatts() -> Double?
}

final class LiveGPUPowerReader: GPUPowerReading, @unchecked Sendable {
    /// One reader for the whole app. Each instance would hold its own IOReport
    /// subscription and energy baseline and walk the accelerator registry for
    /// the fallback and budget properties, so every consumer — the system
    /// metrics monitor, the power scale, the budget — shares this one.
    static let shared = LiveGPUPowerReader()

    private static let acceleratorClassName = "IOAccelerator"
    private static let filteredPowerProperty = "FilteredGPUPower"
    private static let budgetProperty = "MaxGPUAbsolutePower"

    private let lock = NSLock()
    private var energyReader: OpaquePointer?
    private var hasEnergyReader = true

    deinit {
        if let energyReader {
            TempraGPUEnergyReaderDestroy(energyReader)
        }
    }

    func currentWatts() -> Double? {
        switch energyModelWatts() {
        case .watts(let watts):
            return watts
        case .needsBaseline:
            // The interval has started; the next call reports it. Reading the
            // driver's filtered value here would mix two different sources.
            return nil
        case .unavailable:
            return Self.milliwatts(forProperty: Self.filteredPowerProperty)
                .map { $0 / 1000 }
        }
    }

    func budgetWatts() -> Double? {
        Self.milliwatts(forProperty: Self.budgetProperty).map { $0 / 1000 }
    }

    private enum EnergyModelReading {
        case watts(Double)
        case needsBaseline
        case unavailable
    }

    private func energyModelWatts() -> EnergyModelReading {
        lock.lock()
        defer { lock.unlock() }
        guard hasEnergyReader else { return .unavailable }
        if energyReader == nil {
            var reader: OpaquePointer?
            guard TempraGPUEnergyReaderCreate(&reader) == TEMPRA_GPU_ENERGY_READER_OK,
                  let reader else {
                hasEnergyReader = false
                return .unavailable
            }
            energyReader = reader
        }
        var watts: Double = 0
        switch TempraGPUEnergyReaderSample(energyReader, &watts) {
        case TEMPRA_GPU_ENERGY_READER_OK:
            guard watts.isFinite, watts >= 0 else { return .needsBaseline }
            return .watts(watts)
        case TEMPRA_GPU_ENERGY_READER_NEEDS_BASELINE:
            return .needsBaseline
        case TEMPRA_GPU_ENERGY_READER_UNAVAILABLE:
            hasEnergyReader = false
            return .unavailable
        default:
            return .needsBaseline
        }
    }

    private static func milliwatts(forProperty name: String) -> Double? {
        let accelerator = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(acceleratorClassName)
        )
        guard accelerator != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(accelerator) }

        guard let value = IORegistryEntryCreateCFProperty(
            accelerator,
            name as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        let milliwatts = value.doubleValue
        guard milliwatts.isFinite, milliwatts >= 0 else { return nil }
        return milliwatts
    }
}

/// Turns GPU busy share into watts.
///
/// GPU power is not proportional to busy time, because the firmware also moves
/// clocks and voltage: on an M4 Max the same GPU measured 0.46 W while 32% busy
/// at its lowest performance state and 38.7 W while 96% busy at its highest, so
/// a point of busy share cost about 60x more in the second case. The scale is
/// therefore measured, never assumed, and it is refreshed from the whole GPU:
/// watts per share point is the current draw divided by the busy share of every
/// process together. A limit then compares measured watts with the ceiling and
/// corrects itself.
struct GPUPowerScale: Sendable, Equatable {
    /// Below this share the scale is noise: an idle GPU draws its floor power
    /// regardless of the little work on it.
    static let minimumSharePercent: Double = 2

    let wattsPerSharePoint: Double

    init?(totalWatts: Double, totalSharePercent: Double) {
        guard totalWatts.isFinite,
              totalWatts > 0,
              totalSharePercent >= Self.minimumSharePercent else {
            return nil
        }
        let scale = totalWatts / totalSharePercent
        guard scale.isFinite, scale > 0 else { return nil }
        wattsPerSharePoint = scale
    }

    /// The watts a process draws while it keeps `sharePercent` of the GPU busy.
    func watts(forSharePercent sharePercent: Double) -> Double {
        guard sharePercent.isFinite, sharePercent > 0 else { return 0 }
        return sharePercent * wattsPerSharePoint
    }
}

/// Supplies the current share to watt scale for the GPU limit.
protocol GPUPowerScaling: Sendable {
    /// The measured scale, or nil while the GPU is too idle to price a share.
    func currentScale() -> GPUPowerScale?
}

/// Measures the scale from the whole GPU: current power over total busy share.
///
/// One full registry scan costs about 6 ms with a hundred GPU clients, so the
/// measurement is rate limited and cached. Pulse boundaries then only read the
/// processes under control, which costs microseconds.
final class LiveGPUPowerScale: GPUPowerScaling, @unchecked Sendable {
    /// One reader for the whole app: the scan is rate limited inside, so the
    /// monitor and the limiter share a single registry pass each second.
    static let shared = LiveGPUPowerScale()

    private let usageReader: any GPUUsageReading
    private let powerReader: any GPUPowerReading
    private let uptime: () -> TimeInterval
    private let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var sampler = GPUUsageSampler()
    private var lastSampleTime: TimeInterval?
    private var cachedScale: GPUPowerScale?

    init(
        usageReader: any GPUUsageReading = LiveGPUUsageReader.shared,
        powerReader: any GPUPowerReading = LiveGPUPowerReader.shared,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        minimumInterval: TimeInterval = 1
    ) {
        self.usageReader = usageReader
        self.powerReader = powerReader
        self.uptime = uptime
        self.minimumInterval = minimumInterval
    }

    func currentScale() -> GPUPowerScale? {
        let now = uptime()
        lock.lock()
        if let lastSampleTime, now - lastSampleTime < minimumInterval {
            defer { lock.unlock() }
            return cachedScale
        }
        lastSampleTime = now
        let shares = sampler.sample(
            counters: usageReader.accumulatedBusyNanoseconds(),
            at: now
        )
        lock.unlock()

        let totalShare = shares.values.reduce(0, +)
        guard let watts = powerReader.currentWatts(),
              let scale = GPUPowerScale(
                  totalWatts: watts,
                  totalSharePercent: totalShare
              ) else {
            return cachedScale
        }
        lock.lock()
        cachedScale = scale
        lock.unlock()
        return scale
    }
}

/// The GPU power budget this Mac has been seen to allow.
///
/// The firmware narrows `MaxGPUAbsolutePower` while the GPU works, so a single
/// read is not the ceiling. The highest reading is, and the GPU is idle often
/// enough that the peak settles within seconds of launch. The interface offers
/// this as the top of the GPU limit range.
final class GPUPowerBudget: @unchecked Sendable {
    static let shared = GPUPowerBudget()

    private let reader: any GPUPowerReading
    private let lock = NSLock()
    private var observedPeakWatts: Double?

    init(reader: any GPUPowerReading = LiveGPUPowerReader.shared) {
        self.reader = reader
        refresh()
    }

    /// The highest budget seen so far, in watts.
    var peakWatts: Double? {
        lock.lock()
        defer { lock.unlock() }
        return observedPeakWatts
    }

    /// Reads the budget again and keeps the highest value.
    @discardableResult
    func refresh() -> Double? {
        guard let watts = reader.budgetWatts(), watts > 0 else { return peakWatts }
        lock.lock()
        defer { lock.unlock() }
        observedPeakWatts = max(observedPeakWatts ?? 0, watts)
        return observedPeakWatts
    }
}
