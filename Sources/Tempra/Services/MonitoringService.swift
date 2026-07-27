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
    private let systemMetricsMonitor: SystemMetricsMonitor

    init(
        processMonitor: ProcessMonitor = ProcessMonitor(),
        powerMonitor: ProcessPowerMonitor = ProcessPowerMonitor(),
        systemMetricsMonitor: SystemMetricsMonitor = SystemMetricsMonitor()
    ) {
        self.processMonitor = processMonitor
        self.powerMonitor = powerMonitor
        self.systemMetricsMonitor = systemMetricsMonitor
    }

    func sample(_ request: MonitoringRequest) -> MonitoringSample {
        let systemCPU = request.samplesSystemCPU ? systemMetricsMonitor.sample() : nil
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
                powerMetricsSupported: powerMonitor.isSupported
            )
        }

        let apps = processMonitor.sample(
            inventory: inventory,
            includingEssentialSystemProcesses: request.includesEssentialSystemProcesses
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
            powerMetricsSupported: powerMonitor.isSupported
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
