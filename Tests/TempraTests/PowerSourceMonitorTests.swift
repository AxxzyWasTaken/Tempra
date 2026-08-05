import Testing
@testable import Tempra

@Suite("Power source monitoring")
struct PowerSourceMonitorTests {
    @Test("Source states pass through without electrical measurements")
    func sourceStatesPassThrough() {
        var state: PowerSourceState? = .battery
        let monitor = PowerSourceMonitor(stateProvider: { state })

        #expect(monitor.sample() == .battery)
        state = .externalPower
        #expect(monitor.sample() == .externalPower)
        state = nil
        #expect(monitor.sample() == nil)
    }

    @Test("Source states map to automatic profile conditions")
    func profileMapping() {
        #expect(PowerSourceState.battery.profilePowerSource == .battery)
        #expect(PowerSourceState.externalPower.profilePowerSource == .externalPower)
    }
}
