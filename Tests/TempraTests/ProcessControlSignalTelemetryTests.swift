import Foundation
import Testing
@testable import Tempra

@Suite("Process signal telemetry")
struct ProcessControlSignalTelemetryTests {
    @Test("The event ring keeps only the newest entries in order")
    func boundedRingKeepsNewestEvents() async {
        let telemetry = ProcessControlSignalTelemetry(capacity: 3)

        for index in 1...4 {
            let process = ProcessIdentity(
                pid: pid_t(index),
                startTimeMicroseconds: UInt64(index)
            )
            await telemetry.record(ProcessControlSignalEvent(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                bundleIdentifier: "example.app",
                operation: .stop,
                reason: .cpuLimitPulse,
                requested: [process],
                result: ProcessOperationResult(applied: [process]),
                stoppedDurations: [:]
            ))
        }

        let events = await telemetry.snapshot()
        #expect(events.map(\.date) == [
            Date(timeIntervalSince1970: 2),
            Date(timeIntervalSince1970: 3),
            Date(timeIntervalSince1970: 4),
        ])
    }

    @Test("Short-window summaries expose pulse peaks and service gaps")
    func shortWindowSummary() async {
        let telemetry = ProcessControlSignalTelemetry(capacity: 8)
        let start = Date(timeIntervalSince1970: 1_000)

        await telemetry.recordMeasurement(ProcessLimitMeasurement(
            date: start.addingTimeInterval(0.04),
            bundleIdentifier: "first.app",
            kind: .pulse,
            requestedLimitPercent: 8,
            measuredCPUPercent: 100,
            cpuDeltaNanoseconds: 5_000_000,
            wallDuration: 0.005,
            deadlineLateness: 0.001,
            activePulseCount: 1,
            serviceGap: 0.08
        ))
        await telemetry.recordMeasurement(ProcessLimitMeasurement(
            date: start.addingTimeInterval(0.08),
            bundleIdentifier: "second.app",
            kind: .pulse,
            requestedLimitPercent: 8,
            measuredCPUPercent: 100,
            cpuDeltaNanoseconds: 5_000_000,
            wallDuration: 0.005,
            deadlineLateness: 0.002,
            activePulseCount: 2,
            serviceGap: 0.1
        ))

        let summary = await telemetry.summary(since: start)
        #expect(summary.maximumActivePulseCount == 2)
        #expect(summary.maximumServiceGap == 0.1)
        #expect(summary.maximumDeadlineLateness == 0.002)
        #expect(summary.peakCPUPercentByWindow[0.05] == 20)
        #expect(summary.peakCPUPercentByWindow[0.1] == 10)
    }
}
