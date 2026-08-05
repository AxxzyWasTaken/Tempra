import Foundation

struct MonitoringRequest: Sendable {
    let generation: UInt64
    let inventory: ApplicationInventory?
    let samplesSystemCPU: Bool
    let samplesApplications: Bool
    let includesEssentialSystemProcesses: Bool
    let processTableRefreshInterval: TimeInterval
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
    let powerSource: PowerSourceState?
    let privilegedAccessError: String?

    init(
        generation: UInt64,
        systemCPU: SystemCPUSnapshot?,
        apps: [ManagedApp]?,
        didRefreshApplications: Bool,
        powerSource: PowerSourceState? = nil,
        privilegedAccessError: String? = nil
    ) {
        self.generation = generation
        self.systemCPU = systemCPU
        self.apps = apps
        self.didRefreshApplications = didRefreshApplications
        self.powerSource = powerSource
        self.privilegedAccessError = privilegedAccessError
    }

    func withoutApplicationData() -> MonitoringSample {
        MonitoringSample(
            generation: generation,
            systemCPU: systemCPU,
            apps: nil,
            didRefreshApplications: false,
            powerSource: powerSource,
            privilegedAccessError: privilegedAccessError
        )
    }
}

protocol MonitoringServicing: Sendable {
    func sample(_ request: MonitoringRequest) async -> MonitoringSample
    func resetApplicationBaseline() async
    func setTemperatureSamplingInterval(_ interval: TimeInterval?) async
    func shutdown() async
}

actor MonitoringService: MonitoringServicing {
    private let processMonitor: ProcessMonitor
    private let powerSourceMonitor: PowerSourceMonitor
    private let systemMetricsMonitor: SystemMetricsMonitor

    init(
        processMonitor: ProcessMonitor = ProcessMonitor(),
        powerSourceMonitor: PowerSourceMonitor = PowerSourceMonitor(),
        systemMetricsMonitor: SystemMetricsMonitor = SystemMetricsMonitor()
    ) {
        self.processMonitor = processMonitor
        self.powerSourceMonitor = powerSourceMonitor
        self.systemMetricsMonitor = systemMetricsMonitor
    }

    func sample(_ request: MonitoringRequest) async -> MonitoringSample {
        let systemCPU = request.samplesSystemCPU ? systemMetricsMonitor.sample() : nil
        let powerSource = request.samplesSystemCPU ? powerSourceMonitor.sample() : nil
        if let processChange = request.processChange {
            processMonitor.handleProcessChange(processChange)
        }
        guard request.samplesApplications, let inventory = request.inventory else {
            return MonitoringSample(
                generation: request.generation,
                systemCPU: systemCPU,
                apps: nil,
                didRefreshApplications: false,
                powerSource: powerSource
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
        return MonitoringSample(
            generation: request.generation,
            systemCPU: systemCPU,
            apps: apps,
            didRefreshApplications: processMonitor.didRefreshLastSample,
            powerSource: powerSource,
            privilegedAccessError: processMonitor.privilegedAccessError
        )
    }

    func resetApplicationBaseline() {
        processMonitor.resetSamplingBaseline()
    }

    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {
        systemMetricsMonitor.setTemperatureSamplingInterval(interval)
    }

    func shutdown() {
        systemMetricsMonitor.stop()
    }
}
