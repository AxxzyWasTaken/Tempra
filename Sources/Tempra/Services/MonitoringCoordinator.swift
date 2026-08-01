import Foundation

@MainActor
final class MonitoringCoordinator {
    typealias SampleHandler = @MainActor @Sendable (MonitoringSample) -> Void

    private let service: any MonitoringServicing
    private let onSample: SampleHandler
    private var timer: Timer?
    private var configurationTask: Task<Void, Never>?
    private var samplingTask: Task<Void, Never>?
    private var pendingRequest: MonitoringRequest?
    private var deferredProcessChange: ProcessChangeNotification?
    private var applicationBaselineGeneration: UInt64?
    private var generation: UInt64 = 0
    private(set) var demand: MonitoringDemand = .dormant
    private var isStopped = false

    init(
        service: any MonitoringServicing = MonitoringService(),
        onSample: @escaping SampleHandler
    ) {
        self.service = service
        self.onSample = onSample
    }

    func configure(
        demand: MonitoringDemand,
        refreshImmediately: Bool,
        includesEssentialSystemProcesses: Bool
    ) {
        guard !isStopped else { return }
        let previousDemand = self.demand
        self.demand = demand
        generation &+= 1
        if !previousDemand.samplesApplications, demand.samplesApplications {
            applicationBaselineGeneration = generation
        } else if !demand.samplesApplications {
            applicationBaselineGeneration = nil
        }

        timer?.invalidate()
        timer = nil
        deferredProcessChange = ProcessChangeNotification.coalescing(
            deferredProcessChange,
            pendingRequest?.processChange
        )
        pendingRequest = nil

        let previousConfiguration = configurationTask
        configurationTask = Task { [service] in
            await previousConfiguration?.value
            await service.setTemperatureSamplingInterval(demand.temperatureInterval)
            if !previousDemand.samplesApplications, demand.samplesApplications {
                await service.resetApplicationBaseline()
            }
            if !demand.samplesPower {
                await service.resetPowerMetrics()
            }
        }

        if refreshImmediately, demand != .dormant {
            requestPeriodicRefresh(
                includesEssentialSystemProcesses: includesEssentialSystemProcesses
            )
        }

        if let interval = demand.sampleInterval {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.requestPeriodicRefresh(
                        includesEssentialSystemProcesses: includesEssentialSystemProcesses
                    )
                }
            }
            timer.tolerance = min(1, interval * 0.2)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func requestEventRefresh(
        includesEssentialSystemProcesses: Bool,
        processChange: ProcessChangeNotification? = nil
    ) {
        guard !isStopped else { return }
        enqueue(makeRequest(
            samplesSystemCPU: demand != .dormant,
            samplesApplications: true,
            includesEssentialSystemProcesses: includesEssentialSystemProcesses,
            samplesPower: demand.samplesPower,
            processChange: processChange
        ))
    }

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        timer?.invalidate()
        timer = nil
        pendingRequest = nil
        deferredProcessChange = nil
        applicationBaselineGeneration = nil
        samplingTask?.cancel()
        samplingTask = nil
        await configurationTask?.value
        configurationTask = nil
        await service.shutdown()
    }

    private func requestPeriodicRefresh(includesEssentialSystemProcesses: Bool) {
        switch demand {
        case .dormant:
            break
        case .menuBar:
            enqueue(makeRequest(
                samplesSystemCPU: true,
                samplesApplications: false,
                includesEssentialSystemProcesses: false,
                samplesPower: false,
                processChange: nil
            ))
        case .liveUI, .continuous:
            enqueue(makeRequest(
                samplesSystemCPU: true,
                samplesApplications: true,
                includesEssentialSystemProcesses: includesEssentialSystemProcesses,
                samplesPower: demand.samplesPower,
                processChange: nil
            ))
        }
    }

    private func makeRequest(
        samplesSystemCPU: Bool,
        samplesApplications: Bool,
        includesEssentialSystemProcesses: Bool,
        samplesPower: Bool,
        processChange: ProcessChangeNotification?
    ) -> MonitoringRequest {
        MonitoringRequest(
            generation: generation,
            inventory: samplesApplications ? .capture() : nil,
            samplesSystemCPU: samplesSystemCPU,
            samplesApplications: samplesApplications,
            includesEssentialSystemProcesses: includesEssentialSystemProcesses,
            samplesPower: samplesPower,
            processChange: processChange
        )
    }

    private func enqueue(_ request: MonitoringRequest) {
        let request = request.replacingProcessChange(
            with: ProcessChangeNotification.coalescing(
                deferredProcessChange,
                request.processChange
            )
        )
        deferredProcessChange = nil
        guard samplingTask == nil else {
            pendingRequest = request.replacingProcessChange(
                with: ProcessChangeNotification.coalescing(
                    pendingRequest?.processChange,
                    request.processChange
                )
            )
            return
        }
        start(request)
    }

    private func start(_ request: MonitoringRequest) {
        let configurationTask = configurationTask
        samplingTask = Task { [weak self, service, onSample] in
            await configurationTask?.value
            guard !Task.isCancelled else { return }
            let sample = await service.sample(request)
            guard !Task.isCancelled, let self else { return }
            if sample.generation == generation {
                if request.samplesApplications,
                   applicationBaselineGeneration == request.generation {
                    applicationBaselineGeneration = nil
                    onSample(sample.withoutApplicationData())
                } else {
                    onSample(sample)
                }
            }
            samplingTask = nil
            if let pendingRequest {
                self.pendingRequest = nil
                if pendingRequest.generation == generation {
                    start(pendingRequest)
                }
            }
        }
    }
}
