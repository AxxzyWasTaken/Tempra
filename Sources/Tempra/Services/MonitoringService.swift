import Foundation

struct MonitoringRequest: Sendable {
    let generation: UInt64
    let inventory: ApplicationInventory?
    let samplesSystemCPU: Bool
    let samplesApplications: Bool
    let includesEssentialSystemProcesses: Bool
    let samplesPower: Bool
    let processChange: ProcessChangeNotification?

    func replacingProcessChange(
        with processChange: ProcessChangeNotification?
    ) -> MonitoringRequest {
        MonitoringRequest(
            generation: generation,
            inventory: inventory,
            samplesSystemCPU: samplesSystemCPU,
            samplesApplications: samplesApplications,
            includesEssentialSystemProcesses: includesEssentialSystemProcesses,
            samplesPower: samplesPower,
            processChange: processChange
        )
    }
}

struct MonitoringSample: Sendable {
    let generation: UInt64
    let systemCPU: SystemCPUSnapshot?
    let apps: [ManagedApp]?
    let didRefreshApplications: Bool
    let powerByIdentifier: [String: ProcessPowerSample]
    let powerMetricsSupported: Bool
    let batteryPower: BatteryPowerState?
    let privilegedAccessError: String?

    init(
        generation: UInt64,
        systemCPU: SystemCPUSnapshot?,
        apps: [ManagedApp]?,
        didRefreshApplications: Bool,
        powerByIdentifier: [String: ProcessPowerSample],
        powerMetricsSupported: Bool,
        batteryPower: BatteryPowerState? = nil,
        privilegedAccessError: String? = nil
    ) {
        self.generation = generation
        self.systemCPU = systemCPU
        self.apps = apps
        self.didRefreshApplications = didRefreshApplications
        self.powerByIdentifier = powerByIdentifier
        self.powerMetricsSupported = powerMetricsSupported
        self.batteryPower = batteryPower
        self.privilegedAccessError = privilegedAccessError
    }
}

protocol MonitoringServicing: Sendable {
    func sample(_ request: MonitoringRequest) async -> MonitoringSample
    func resetApplicationBaseline() async
    func resetPowerMetrics() async
    func setTemperatureSamplingInterval(_ interval: TimeInterval?) async
    func shutdown() async
}

actor MonitoringService: MonitoringServicing {
    private let processMonitor: ProcessMonitor
    private let powerMonitor: ProcessPowerMonitor
    private let batteryPowerMonitor: BatteryPowerMonitor
    private let systemMetricsMonitor: SystemMetricsMonitor

    init(
        processMonitor: ProcessMonitor = ProcessMonitor(),
        powerMonitor: ProcessPowerMonitor = ProcessPowerMonitor(),
        batteryPowerMonitor: BatteryPowerMonitor = BatteryPowerMonitor(),
        systemMetricsMonitor: SystemMetricsMonitor = SystemMetricsMonitor()
    ) {
        self.processMonitor = processMonitor
        self.powerMonitor = powerMonitor
        self.batteryPowerMonitor = batteryPowerMonitor
        self.systemMetricsMonitor = systemMetricsMonitor
    }

    func sample(_ request: MonitoringRequest) async -> MonitoringSample {
        let systemCPU = request.samplesSystemCPU ? systemMetricsMonitor.sample() : nil
        let batteryPower = request.samplesSystemCPU ? batteryPowerMonitor.sample() : nil
        if let processChange = request.processChange {
            processMonitor.handleProcessChange(processChange)
        }
        guard request.samplesApplications, let inventory = request.inventory else {
            return MonitoringSample(
                generation: request.generation,
                systemCPU: systemCPU,
                apps: nil,
                didRefreshApplications: false,
                powerByIdentifier: [:],
                powerMetricsSupported: powerMonitor.isSupported,
                batteryPower: batteryPower
            )
        }

        let apps = await processMonitor.sample(
            inventory: inventory,
            includingEssentialSystemProcesses: request.includesEssentialSystemProcesses,
            refreshesAudioActivity: request.processChange?.audioActivityChanged != false
        )
        let powerByIdentifier: [String: ProcessPowerSample]
        if request.samplesPower {
            powerByIdentifier = powerMonitor.sample(groups: apps.map {
                ProcessPowerGroup(
                    identifier: $0.bundleIdentifier,
                    processIdentifiers: $0.processIdentifiers
                )
            })
        } else {
            powerMonitor.reset()
            powerByIdentifier = [:]
        }

        return MonitoringSample(
            generation: request.generation,
            systemCPU: systemCPU,
            apps: apps,
            didRefreshApplications: processMonitor.didRefreshLastSample,
            powerByIdentifier: powerByIdentifier,
            powerMetricsSupported: powerMonitor.isSupported,
            batteryPower: batteryPower,
            privilegedAccessError: processMonitor.privilegedAccessError
        )
    }

    func resetApplicationBaseline() {
        processMonitor.resetSamplingBaseline()
    }

    func resetPowerMetrics() {
        powerMonitor.reset()
    }

    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {
        systemMetricsMonitor.setTemperatureSamplingInterval(interval)
    }

    func shutdown() {
        powerMonitor.reset()
        systemMetricsMonitor.stop()
    }
}
