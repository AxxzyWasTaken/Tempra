import Foundation
import Testing
@testable import Tempra

@Suite("Monitoring demand")
struct MonitoringDemandTests {
    @Test("Process events promote monitoring work to latency-sensitive priority")
    func processEventsPromoteMonitoringPriority() {
        let periodicRequest = MonitoringRequest(
            generation: 1,
            inventory: nil,
            samplesSystemCPU: true,
            samplesApplications: false,
            includesEssentialSystemProcesses: false,
            processChange: nil
        )

        #expect(!periodicRequest.isLatencySensitive)
        #expect(periodicRequest.replacingProcessChange(
            with: .audioActivity
        ).isLatencySensitive)
        #expect(periodicRequest.requiringLatencySensitiveSampling().isLatencySensitive)
    }

    @Test("Dormant mode has no recurring work")
    func dormantHasNoRecurringWork() {
        let demand = MonitoringDemand.resolve(
            isPresentationActive: false,
            isContinuousMonitoringEnabled: false,
            showsCPUUsageInMenuBar: false
        )

        #expect(demand == .dormant)
        #expect(demand.sampleInterval == nil)
        #expect(demand.temperatureInterval == nil)
    }

    @Test("Visible UI takes precedence over continuous monitoring")
    func liveUIPrecedence() {
        let demand = MonitoringDemand.resolve(
            isPresentationActive: true,
            isContinuousMonitoringEnabled: true,
            showsCPUUsageInMenuBar: true
        )

        #expect(demand == .liveUI)
        #expect(demand.sampleInterval == 1)
        #expect(demand.temperatureInterval == 2)
        #expect(demand.processTableRefreshInterval == 5)
        #expect(demand.refreshesAudioActivity)
    }

    @Test("Continuous monitoring uses coarse intervals")
    func continuousIntervals() {
        let demand = MonitoringDemand.resolve(
            isPresentationActive: false,
            isContinuousMonitoringEnabled: true,
            showsCPUUsageInMenuBar: false
        )

        #expect(demand == .continuous)
        #expect(demand.sampleInterval == 5)
        #expect(demand.temperatureInterval == 15)
        #expect(demand.processTableRefreshInterval == 15)
    }

    @Test("Menu-bar CPU uses only a coarse system sample")
    func menuBarIntervals() {
        let demand = MonitoringDemand.resolve(
            isPresentationActive: false,
            isContinuousMonitoringEnabled: false,
            showsCPUUsageInMenuBar: true
        )

        #expect(demand == .menuBar)
        #expect(demand.sampleInterval == 5)
        #expect(demand.temperatureInterval == nil)
        #expect(demand.processTableRefreshInterval == 30)
        #expect(!demand.samplesApplications)
    }

    @Test("Active rules sample applications without enabling optional metrics")
    func managementIntervals() {
        let demand = MonitoringDemand.resolve(
            isPresentationActive: false,
            isContinuousMonitoringEnabled: false,
            showsCPUUsageInMenuBar: false,
            requiresApplicationMonitoring: true
        )

        #expect(demand == .management(samplesSystemCPU: false))
        #expect(demand.sampleInterval == 5)
        #expect(demand.temperatureInterval == nil)
        #expect(demand.samplesApplications)
        #expect(!demand.recordsApplicationMetrics)
        #expect(!demand.samplesSystemCPU)
        #expect(!demand.refreshesAudioActivity)
    }

    @Test("High CPU alerts use app sampling without optional power metrics")
    func highCPUAlertIntervals() {
        let demand = MonitoringDemand.resolve(
            isPresentationActive: false,
            isContinuousMonitoringEnabled: false,
            showsCPUUsageInMenuBar: false,
            requiresHighCPUDetection: true
        )

        #expect(demand == .highCPUAlerts(samplesSystemCPU: false))
        #expect(demand.sampleInterval == 5)
        #expect(demand.temperatureInterval == nil)
        #expect(demand.processTableRefreshInterval == 30)
        #expect(demand.samplesApplications)
        #expect(demand.detectsHighCPU)
        #expect(!demand.recordsApplicationMetrics)
        #expect(!demand.samplesSystemCPU)
        #expect(!demand.refreshesAudioActivity)
    }

    @Test("Rule maintenance preserves requested menu-bar CPU sampling")
    func managementIncludesRequestedSystemCPU() {
        let demand = MonitoringDemand.resolve(
            isPresentationActive: false,
            isContinuousMonitoringEnabled: false,
            showsCPUUsageInMenuBar: true,
            requiresApplicationMonitoring: true
        )

        #expect(demand == .management(samplesSystemCPU: true))
        #expect(demand.samplesSystemCPU)
    }

    @Test("Continuous metrics use the coarse management sampling cadence")
    func continuousManagementIntervals() {
        let demand = MonitoringDemand.resolve(
            isPresentationActive: false,
            isContinuousMonitoringEnabled: true,
            showsCPUUsageInMenuBar: false,
            requiresApplicationMonitoring: true
        )

        #expect(demand == .continuousManagement)
        #expect(demand.sampleInterval == 5)
        #expect(demand.temperatureInterval == 15)
        #expect(demand.processTableRefreshInterval == 15)
        #expect(demand.recordsApplicationMetrics)
        #expect(demand.samplesSystemCPU)
    }

    @Test("Automatic profiles keep context sampling active")
    func automaticProfileContextIntervals() {
        let demand = MonitoringDemand.resolve(
            isPresentationActive: false,
            isContinuousMonitoringEnabled: false,
            showsCPUUsageInMenuBar: false,
            requiresContextMonitoring: true
        )

        #expect(demand == .menuBar)
        #expect(demand.sampleInterval == 5)
        #expect(!demand.samplesApplications)
    }

    @Test("Opening the menu keeps the last app values while establishing a baseline")
    @MainActor
    func openingMenuPreservesAppValuesDuringBaseline() async throws {
        let service = BaselineMonitoringService()
        var receivedSamples: [MonitoringSample] = []
        let coordinator = MonitoringCoordinator(service: service) { sample in
            receivedSamples.append(sample)
        }

        coordinator.configure(
            demand: .liveUI,
            refreshImmediately: true,
            includesEssentialSystemProcesses: true
        )
        try await waitForSampleCount(1, samples: { receivedSamples })

        #expect(receivedSamples[0].apps == nil)
        #expect(receivedSamples[0].systemCPU?.totalPercent == 10)

        coordinator.requestEventRefresh(includesEssentialSystemProcesses: true)
        try await waitForSampleCount(2, samples: { receivedSamples })

        #expect(receivedSamples[1].apps?.first?.cpuPercent == 42)
        await coordinator.shutdown()
    }

    @Test("Refreshes during a sample coalesce into one pending request")
    @MainActor
    func activeSampleCoalescesPendingRefreshes() async throws {
        let service = ControlledMonitoringService()
        var receivedSamples: [MonitoringSample] = []
        let coordinator = MonitoringCoordinator(service: service) { sample in
            receivedSamples.append(sample)
        }
        let identity = ProcessIdentity(
            pid: 400,
            startTimeMicroseconds: 4_000_000
        )
        let processChange = ProcessChangeNotification(
            invalidatedMetadata: [identity],
            processTableChanged: true,
            audioActivityChanged: false
        )

        coordinator.configure(
            demand: .management(samplesSystemCPU: false),
            refreshImmediately: true,
            includesEssentialSystemProcesses: false
        )
        await service.waitForFirstSample()
        coordinator.requestEventRefresh(
            includesEssentialSystemProcesses: false,
            processChange: .audioActivity
        )
        coordinator.requestEventRefresh(
            includesEssentialSystemProcesses: false,
            processChange: processChange
        )
        await service.releaseFirstSample()

        try await waitForSampleCount(2, samples: { receivedSamples })
        let requests = await service.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[1].processChange == ProcessChangeNotification(
            invalidatedMetadata: [identity],
            processTableChanged: true,
            audioActivityChanged: true
        ))
        await coordinator.shutdown()
    }

    @Test("Shutdown discards a sample that completes after cancellation")
    @MainActor
    func shutdownDiscardsLateSample() async {
        let service = ControlledMonitoringService()
        var receivedSamples: [MonitoringSample] = []
        let coordinator = MonitoringCoordinator(service: service) { sample in
            receivedSamples.append(sample)
        }

        coordinator.configure(
            demand: .management(samplesSystemCPU: false),
            refreshImmediately: true,
            includesEssentialSystemProcesses: false
        )
        await service.waitForFirstSample()
        await coordinator.shutdown()
        #expect(await service.shutdownCallCount() == 1)

        await service.releaseFirstSample()
        await service.waitForFirstSampleCompletion()
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(receivedSamples.isEmpty)
    }

    @Test("The open interface follows every process event")
    func openInterfaceFollowsEveryProcessEvent() {
        #expect(MonitoringDemand.liveUI.eventRefreshInterval == 0)
        #expect(MonitoringDemand.management(samplesSystemCPU: true)
            .eventRefreshInterval == 1)
        #expect(MonitoringDemand.highCPUAlerts(samplesSystemCPU: false)
            .eventRefreshInterval == 1)
        #expect(MonitoringDemand.continuousManagement.eventRefreshInterval == 1)
    }

    @Test("A churning process table costs one paced sample while the menu is closed")
    @MainActor
    func closedMenuPacesProcessEventSamples() async throws {
        let service = RecordingMonitoringService()
        var receivedSamples: [MonitoringSample] = []
        // The pacing gap is measured, not waited out, so the test drives the
        // clock itself. A loaded machine can otherwise spend longer than the
        // one second gap between the anchor sample and the churn below, which
        // makes every event sample immediately and paces nothing.
        let clock = TestInstantClock()
        let coordinator = MonitoringCoordinator(
            service: service,
            now: { clock.now }
        ) { sample in
            receivedSamples.append(sample)
        }
        let firstIdentity = ProcessIdentity(pid: 501, startTimeMicroseconds: 5_000_000)
        let secondIdentity = ProcessIdentity(pid: 502, startTimeMicroseconds: 5_100_000)

        coordinator.configure(
            demand: .management(samplesSystemCPU: false),
            refreshImmediately: true,
            includesEssentialSystemProcesses: false
        )
        try await waitForSampleCount(1, samples: { receivedSamples })

        for identity in [firstIdentity, secondIdentity, firstIdentity] {
            coordinator.requestEventRefresh(
                includesEssentialSystemProcesses: false,
                processChange: ProcessChangeNotification(
                    invalidatedMetadata: [identity],
                    processTableChanged: true,
                    audioActivityChanged: false
                )
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(receivedSamples.count == 1)

        // The deferred refresh wakes after the real one second gap and asks
        // again; by then the paced gap has genuinely elapsed.
        clock.advance(by: .seconds(1))
        try await waitForSampleCount(2, samples: { receivedSamples }, attempts: 300)
        let requests = await service.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[1].processChange == ProcessChangeNotification(
            invalidatedMetadata: [firstIdentity, secondIdentity],
            processTableChanged: true,
            audioActivityChanged: false
        ))
        await coordinator.shutdown()
    }

    @Test("An audio change samples without waiting out the gap")
    @MainActor
    func audioChangeSamplesImmediately() async throws {
        let service = RecordingMonitoringService()
        var receivedSamples: [MonitoringSample] = []
        let coordinator = MonitoringCoordinator(service: service) { sample in
            receivedSamples.append(sample)
        }

        coordinator.configure(
            demand: .management(samplesSystemCPU: false),
            refreshImmediately: true,
            includesEssentialSystemProcesses: false
        )
        try await waitForSampleCount(1, samples: { receivedSamples })

        coordinator.requestEventRefresh(
            includesEssentialSystemProcesses: false,
            processChange: .audioActivity
        )
        try await waitForSampleCount(2, samples: { receivedSamples })
        await coordinator.shutdown()
    }

    @MainActor
    private func waitForSampleCount(
        _ count: Int,
        samples: () -> [MonitoringSample],
        attempts: Int = 100
    ) async throws {
        for _ in 0..<attempts {
            if samples().count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MonitoringSampleTimeout()
    }
}

private struct MonitoringSampleTimeout: Error {}

/// A clock the test advances by hand, so a paced gap is decided by the test
/// rather than by how long a loaded machine took to get between two lines.
private final class TestInstantClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.advanced(by: duration)
    }
}

private actor RecordingMonitoringService: MonitoringServicing {
    private var requests: [MonitoringRequest] = []

    func sample(_ request: MonitoringRequest) -> MonitoringSample {
        requests.append(request)
        return MonitoringSample(
            generation: request.generation,
            systemCPU: nil,
            apps: [],
            didRefreshApplications: true
        )
    }

    func recordedRequests() -> [MonitoringRequest] {
        requests
    }

    func resetApplicationBaseline() {}
    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {}
    func shutdown() {}
}

private actor BaselineMonitoringService: MonitoringServicing {
    private var sampleCount = 0

    func sample(_ request: MonitoringRequest) -> MonitoringSample {
        sampleCount += 1
        let app = ManagedApp(
            bundleIdentifier: "example.app",
            name: "Example",
            bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
            processIdentifiers: [100],
            cpuPercent: sampleCount == 1 ? 0 : 42,
            isFrontmost: false,
            isHidden: false,
            isPlayingAudio: false,
            isSystemProcess: false,
            status: .normal
        )
        return MonitoringSample(
            generation: request.generation,
            systemCPU: SystemCPUSnapshot(totalPercent: 10),
            apps: [app],
            didRefreshApplications: true
        )
    }

    func resetApplicationBaseline() {}
    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {}
    func shutdown() {}
}

private actor ControlledMonitoringService: MonitoringServicing {
    private var requests: [MonitoringRequest] = []
    private var firstSampleStarted: CheckedContinuation<Void, Never>?
    private var firstSampleRelease: CheckedContinuation<Void, Never>?
    private var firstSampleCompleted = false
    private var firstSampleCompletion: CheckedContinuation<Void, Never>?
    private var shutdownCalls = 0

    func sample(_ request: MonitoringRequest) async -> MonitoringSample {
        requests.append(request)
        if requests.count == 1 {
            firstSampleStarted?.resume()
            firstSampleStarted = nil
            await withCheckedContinuation { continuation in
                firstSampleRelease = continuation
            }
            firstSampleCompleted = true
            firstSampleCompletion?.resume()
            firstSampleCompletion = nil
        }
        return MonitoringSample(
            generation: request.generation,
            systemCPU: nil,
            apps: [],
            didRefreshApplications: true
        )
    }

    func waitForFirstSample() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstSampleStarted = continuation
        }
    }

    func releaseFirstSample() {
        firstSampleRelease?.resume()
        firstSampleRelease = nil
    }

    func waitForFirstSampleCompletion() async {
        guard !firstSampleCompleted else { return }
        await withCheckedContinuation { continuation in
            firstSampleCompletion = continuation
        }
    }

    func recordedRequests() -> [MonitoringRequest] {
        requests
    }

    func shutdownCallCount() -> Int {
        shutdownCalls
    }

    func resetApplicationBaseline() {}
    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {}

    func shutdown() {
        shutdownCalls += 1
    }
}
