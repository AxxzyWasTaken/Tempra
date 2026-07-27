import Darwin
import Foundation

final class SystemMetricsMonitor {
    private struct CoreTicks {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32
    }

    private var previousTicks: [CoreTicks] = []
    private let performanceCoreCount: Int
    private let efficiencyCoreCount: Int
    private let temperatureMonitor = CPUTemperatureMonitor()

    init() {
        performanceCoreCount = Self.sysctlInteger("hw.perflevel0.logicalcpu")
            ?? ProcessInfo.processInfo.activeProcessorCount
        efficiencyCoreCount = Self.sysctlInteger("hw.perflevel1.logicalcpu") ?? 0
    }

    func sample() -> SystemCPUSnapshot {
        let current = readCoreTicks()
        defer { previousTicks = current }

        guard current.count == previousTicks.count, !current.isEmpty else {
            return SystemCPUSnapshot(
                performanceCoreCount: min(performanceCoreCount, current.count),
                efficiencyCoreCount: min(efficiencyCoreCount, current.count),
                cpuTemperatureCelsius: temperatureMonitor.currentTemperatureCelsius,
                thermalPressure: Self.currentThermalPressure
            )
        }

        let usage = zip(current, previousTicks).map { current, previous in
            Self.usagePercent(current: current, previous: previous)
        }
        // Apple Silicon exposes efficiency cores at the lowest logical CPU IDs,
        // followed by performance cores. Intel reports no efficiency perf level.
        let efficiencyCount = min(efficiencyCoreCount, usage.count)
        let performanceStart = efficiencyCount
        let performanceCount = min(
            performanceCoreCount,
            max(0, usage.count - performanceStart)
        )

        let totalPercent = Self.average(usage)
        let efficiencyContribution = Self.contribution(
            Array(usage.prefix(efficiencyCount)),
            totalCoreCount: usage.count
        )

        return SystemCPUSnapshot(
            totalPercent: totalPercent,
            performancePercent: max(0, totalPercent - efficiencyContribution),
            efficiencyPercent: efficiencyContribution,
            performanceCoreCount: performanceCount,
            efficiencyCoreCount: efficiencyCount,
            cpuTemperatureCelsius: temperatureMonitor.currentTemperatureCelsius,
            thermalPressure: Self.currentThermalPressure
        )
    }

    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {
        if let interval {
            temperatureMonitor.start(samplingEvery: interval)
        } else {
            previousTicks.removeAll()
            temperatureMonitor.stop()
        }
    }

    func stop() {
        temperatureMonitor.stop()
    }

    private func readCoreTicks() -> [CoreTicks] {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &infoCount
        )
        guard result == KERN_SUCCESS, let cpuInfo else { return [] }

        defer {
            let byteCount = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: cpuInfo)),
                byteCount
            )
        }

        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { index in
            let base = index * stride
            return CoreTicks(
                user: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    private static func usagePercent(current: CoreTicks, previous: CoreTicks) -> Double {
        let user = UInt64(current.user &- previous.user)
        let system = UInt64(current.system &- previous.system)
        let idle = UInt64(current.idle &- previous.idle)
        let nice = UInt64(current.nice &- previous.nice)
        let active = user + system + nice
        let total = active + idle
        guard total > 0 else { return 0 }
        return Double(active) / Double(total) * 100
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func contribution(_ values: [Double], totalCoreCount: Int) -> Double {
        guard totalCoreCount > 0 else { return 0 }
        return values.reduce(0, +) / Double(totalCoreCount)
    }

    private static func sysctlInteger(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static var currentThermalPressure: ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}
