import Foundation
import Testing
@testable import Tempra

@Suite("Monitoring demand")
struct MonitoringDemandTests {
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
        #expect(demand.samplesPower)
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
