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
            samplesPower: false,
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
        #expect(!demand.samplesPower)
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
        #expect(demand.samplesPower)
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
        #expect(!demand.samplesPower)
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
        #expect(!demand.samplesPower)
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
        #expect(!demand.samplesPower)
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
        #expect(!demand.samplesPower)
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
        #expect(!demand.samplesPower)
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

    @MainActor
    private func waitForSampleCount(
        _ count: Int,
        samples: () -> [MonitoringSample]
    ) async throws {
        for _ in 0..<100 {
            if samples().count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MonitoringSampleTimeout()
    }
}

private struct MonitoringSampleTimeout: Error {}

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
            didRefreshApplications: true,
            powerByIdentifier: [:],
            powerMetricsSupported: false
        )
    }

    func resetApplicationBaseline() {}
    func resetPowerMetrics() {}
    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {}
    func shutdown() {}
}
