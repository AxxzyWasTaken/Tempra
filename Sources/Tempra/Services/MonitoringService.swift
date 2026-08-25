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

/// Serializes access to the process monitor across the service's own
/// suspension points, in FIFO order. Kept deliberately boring: it holds at
/// most a couple of waiters, so a plain queue beats clever bookkeeping.
private actor MonitoringOperationGate {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` alone: nothing else touches the monitor until it returns.
    func withExclusiveAccess<T>(_ body: () async -> T) async -> T {
        await enter()
        defer { leave() }
        return await body()
    }

    private func enter() async {
        guard isOccupied else {
            isOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func leave() {
        guard waiters.isEmpty else {
            waiters.removeFirst().resume()
            return
        }
        isOccupied = false
    }
}

actor MonitoringService: MonitoringServicing {
    private let processMonitor: ProcessMonitor
    private let processMonitorGate = MonitoringOperationGate()
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

    /// Runs `body` with exclusive access to the process monitor. `sample`
    /// suspends mid-operation, so without the gate a reentrant call could
    /// interleave a baseline reset or a process change into a running sample.
    private func withProcessMonitor<T>(
        _ body: @escaping (ProcessMonitor) async -> T
    ) async -> T {
        await processMonitorGate.withExclusiveAccess { [processMonitor] in
            await body(processMonitor)
        }
    }

    func sample(_ request: MonitoringRequest) async -> MonitoringSample {
        let systemCPU = request.samplesSystemCPU ? systemMetricsMonitor.sample() : nil
        let powerSource = request.samplesSystemCPU ? powerSourceMonitor.sample() : nil
        guard request.samplesApplications, let inventory = request.inventory else {
            if let processChange = request.processChange {
                await withProcessMonitor { $0.handleProcessChange(processChange) }
            }
            return MonitoringSample(
                generation: request.generation,
                systemCPU: systemCPU,
                apps: nil,
                didRefreshApplications: false,
                powerSource: powerSource
            )
        }

        let (apps, didRefreshApplications, privilegedAccessError) = await withProcessMonitor {
            monitor -> ([ManagedApp], Bool, String?) in
            if let processChange = request.processChange {
                monitor.handleProcessChange(processChange)
            }
            let apps = await monitor.sample(
                inventory: inventory,
                includingEssentialSystemProcesses: request.includesEssentialSystemProcesses,
                processTableRefreshInterval: request.processTableRefreshInterval,
                refreshesAudioActivity: request.refreshesAudioActivity
                    || request.processChange?.audioActivityChanged == true,
                networkActivityBundleIdentifiers: request.networkActivityBundleIdentifiers
            )
            return (apps, monitor.didRefreshLastSample, monitor.privilegedAccessError)
        }
        return MonitoringSample(
            generation: request.generation,
            systemCPU: systemCPU,
            apps: apps,
            didRefreshApplications: didRefreshApplications,
            powerSource: powerSource,
            privilegedAccessError: privilegedAccessError
        )
    }

    func resetApplicationBaseline() async {
        await withProcessMonitor { $0.resetSamplingBaseline() }
    }

    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {
        systemMetricsMonitor.setTemperatureSamplingInterval(interval)
    }

    func shutdown() {
        systemMetricsMonitor.stop()
    }
}
