import Foundation

struct MonitoringRequest: Sendable {
    let generation: UInt64
    let inventory: ApplicationInventory?
    let samplesSystemCPU: Bool
    let samplesApplications: Bool
    let includesEssentialSystemProcesses: Bool
    let processTableRefreshInterval: TimeInterval
    let samplesPower: Bool
    let networkActivityBundleIdentifiers: Set<String>
    let refreshesAudioActivity: Bool
    let isLatencySensitive: Bool
    let processChange: ProcessChangeNotification?

    init(
        generation: UInt64,
        inventory: ApplicationInventory?,
        samplesSystemCPU: Bool,
        samplesApplications: Bool,
        includesEssentialSystemProcesses: Bool,
        processTableRefreshInterval: TimeInterval = 5,
        samplesPower: Bool,
        networkActivityBundleIdentifiers: Set<String> = [],
        refreshesAudioActivity: Bool = false,
        isLatencySensitive: Bool = false,
        processChange: ProcessChangeNotification?
    ) {
        self.generation = generation
        self.inventory = inventory
        self.samplesSystemCPU = samplesSystemCPU
        self.samplesApplications = samplesApplications
        self.includesEssentialSystemProcesses = includesEssentialSystemProcesses
        self.processTableRefreshInterval = processTableRefreshInterval
        self.samplesPower = samplesPower
        self.networkActivityBundleIdentifiers = networkActivityBundleIdentifiers
        self.refreshesAudioActivity = refreshesAudioActivity
        self.isLatencySensitive = isLatencySensitive
        self.processChange = processChange
    }

    func replacingProcessChange(
        with processChange: ProcessChangeNotification?
    ) -> MonitoringRequest {
        MonitoringRequest(
            generation: generation,
            inventory: inventory,
            samplesSystemCPU: samplesSystemCPU,
            samplesApplications: samplesApplications,
            includesEssentialSystemProcesses: includesEssentialSystemProcesses,
            processTableRefreshInterval: processTableRefreshInterval,
            samplesPower: samplesPower,
            networkActivityBundleIdentifiers: networkActivityBundleIdentifiers,
            refreshesAudioActivity: refreshesAudioActivity,
            isLatencySensitive: isLatencySensitive || processChange != nil,
            processChange: processChange
        )
    }

    func requiringLatencySensitiveSampling() -> MonitoringRequest {
        guard !isLatencySensitive else { return self }
        return MonitoringRequest(
            generation: generation,
            inventory: inventory,
            samplesSystemCPU: samplesSystemCPU,
            samplesApplications: samplesApplications,
            includesEssentialSystemProcesses: includesEssentialSystemProcesses,
            processTableRefreshInterval: processTableRefreshInterval,
            samplesPower: samplesPower,
            networkActivityBundleIdentifiers: networkActivityBundleIdentifiers,
            refreshesAudioActivity: refreshesAudioActivity,
            isLatencySensitive: true,
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

    func withoutApplicationData() -> MonitoringSample {
        MonitoringSample(
            generation: generation,
            systemCPU: systemCPU,
            apps: nil,
            didRefreshApplications: false,
            powerByIdentifier: [:],
            powerMetricsSupported: powerMetricsSupported,
            batteryPower: batteryPower,
            privilegedAccessError: privilegedAccessError
        )
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
            processTableRefreshInterval: request.processTableRefreshInterval,
            refreshesAudioActivity: request.refreshesAudioActivity
                || request.processChange?.audioActivityChanged == true,
            networkActivityBundleIdentifiers: request.networkActivityBundleIdentifiers
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
