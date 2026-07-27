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
}
