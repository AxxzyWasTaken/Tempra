import Darwin
import Foundation
import Testing
@testable import Tempra

@Suite("Process network limit calibrator")
struct ProcessNetworkLimitCalibratorTests {
    private let identifier = "com.example.OnlineGame"

    @Test("Stable connections increase the stop interval in bounded steps")
    func stableConnectionIncreasesStopInterval() {
        var calibrator = ProcessNetworkLimitCalibrator(configuration: configuration())
        let process = process(1)
        let connection = connection(1, process: process)
        let startedAt = ContinuousClock().now

        let initial = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(connection),
            learnedStopDuration: nil,
            now: startedAt
        )
        #expect(initial.stopDuration == 0.5)

        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(connection),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(1))
        )
        let firstCandidate = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(connection),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(2))
        )
        #expect(firstCandidate.stopDuration == 0.75)
        #expect(firstCandidate.learnedStopDuration == nil)

        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(connection),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(3))
        )
        let secondCandidate = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(connection),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(4))
        )
        #expect(secondCandidate.stopDuration == 1.125)
        #expect(secondCandidate.learnedStopDuration == 0.75)
    }

    @Test("A changed connection returns to the last stable interval")
    func changedConnectionRollsBackCandidate() {
        var calibrator = ProcessNetworkLimitCalibrator(configuration: configuration())
        let process = process(2)
        let originalConnection = connection(2, process: process)
        let replacementConnection = connection(3, process: process)
        let startedAt = ContinuousClock().now

        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(originalConnection),
            learnedStopDuration: nil,
            now: startedAt
        )
        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(originalConnection),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(1))
        )
        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(originalConnection),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(2))
        )
        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(originalConnection),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(3))
        )
        let testingLongerInterval = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(originalConnection),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(4))
        )
        #expect(testingLongerInterval.stopDuration == 1.125)

        let rollback = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(replacementConnection),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(5))
        )
        #expect(rollback.detectedConnectionWarning)
        #expect(rollback.stopDuration == 0.75)

        let blocked = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(replacementConnection),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(30))
        )
        #expect(blocked.stopDuration == 0.75)
    }

    @Test("A saved interval is tested again after the baseline")
    func learnedIntervalIsReconfirmed() {
        var calibrator = ProcessNetworkLimitCalibrator(configuration: configuration())
        let process = process(3)
        let connection = connection(4, process: process)
        let startedAt = ContinuousClock().now

        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(connection),
            learnedStopDuration: 1.5,
            now: startedAt
        )
        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(connection),
            learnedStopDuration: 1.5,
            now: startedAt.advanced(by: .seconds(1))
        )
        let update = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(connection),
            learnedStopDuration: 1.5,
            now: startedAt.advanced(by: .seconds(2))
        )

        #expect(update.stopDuration == 1.5)
        #expect(update.learnedStopDuration == nil)
    }

    @Test("An unrelated partial probe does not hide a confirmed connection")
    func confirmedConnectionSurvivesPartialProbe() {
        var calibrator = ProcessNetworkLimitCalibrator(configuration: configuration())
        let process = process(7)
        let connection = connection(8, process: process)
        let startedAt = ContinuousClock().now

        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: connectedSnapshot(connection),
            learnedStopDuration: nil,
            now: startedAt
        )
        let partialSnapshot = ProcessNetworkConnectionSnapshot(
            activity: .active,
            activeConnections: [connection],
            isComplete: false
        )
        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: partialSnapshot,
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(1))
        )
        let update = calibrator.update(
            identifier: identifier,
            processIdentities: [process],
            snapshot: partialSnapshot,
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(2))
        )

        #expect(update.stopDuration == 0.75)
        #expect(!update.detectedConnectionWarning)
    }

    @Test("A process restart starts again at the baseline")
    func processRestartResetsCalibration() {
        var calibrator = ProcessNetworkLimitCalibrator(configuration: configuration())
        let firstProcess = process(4)
        let secondProcess = process(5)
        let startedAt = ContinuousClock().now

        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [firstProcess],
            snapshot: connectedSnapshot(connection(5, process: firstProcess)),
            learnedStopDuration: nil,
            now: startedAt
        )
        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [firstProcess],
            snapshot: connectedSnapshot(connection(5, process: firstProcess)),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(1))
        )
        _ = calibrator.update(
            identifier: identifier,
            processIdentities: [firstProcess],
            snapshot: connectedSnapshot(connection(5, process: firstProcess)),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(2))
        )

        let restarted = calibrator.update(
            identifier: identifier,
            processIdentities: [secondProcess],
            snapshot: connectedSnapshot(connection(6, process: secondProcess)),
            learnedStopDuration: nil,
            now: startedAt.advanced(by: .seconds(3))
        )
        #expect(restarted.stopDuration == 0.5)
        #expect(!restarted.detectedConnectionWarning)
    }

    @Test("The interval never exceeds the conservative ceiling")
    func intervalHasConservativeCeiling() {
        let fastConfiguration = ProcessNetworkLimitCalibrationConfiguration(
            baselineStopDuration: 0.5,
            maximumStopDuration: 2,
            validationDuration: 0.001,
            minimumHealthySamples: 1
        )
        var calibrator = ProcessNetworkLimitCalibrator(configuration: fastConfiguration)
        let process = process(6)
        let connection = connection(7, process: process)
        let startedAt = ContinuousClock().now

        for second in 0...12 {
            let update = calibrator.update(
                identifier: identifier,
                processIdentities: [process],
                snapshot: connectedSnapshot(connection),
                learnedStopDuration: nil,
                now: startedAt.advanced(by: .seconds(second))
            )
            #expect(update.stopDuration <= 2)
        }
        #expect(calibrator.stopDuration(
            for: identifier,
            processIdentities: [process]
        ) == 2)
    }

    @Test("Learned intervals persist per game")
    func learnedIntervalPersistence() throws {
        let suiteName = "TempraNetworkCalibrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsProcessNetworkLimitCalibrationStore(defaults: defaults)

        #expect(store.learnedStopDuration(for: identifier) == nil)
        #expect(store.saveLearnedStopDuration(1.5, for: identifier))
        #expect(store.learnedStopDuration(for: identifier) == 1.5)
        #expect(!store.saveLearnedStopDuration(.infinity, for: identifier))
    }

    private func configuration() -> ProcessNetworkLimitCalibrationConfiguration {
        ProcessNetworkLimitCalibrationConfiguration(
            baselineStopDuration: 0.5,
            maximumStopDuration: 2,
            validationDuration: 2,
            minimumHealthySamples: 2
        )
    }

    private func process(_ index: Int32) -> ProcessIdentity {
        ProcessIdentity(
            pid: 30_000 + index,
            startTimeMicroseconds: UInt64(index)
        )
    }

    private func connection(
        _ index: UInt64,
        process: ProcessIdentity
    ) -> ProcessNetworkConnectionID {
        ProcessNetworkConnectionID(
            process: process,
            socketObject: index,
            protocolControlBlock: index + 1_000,
            protocolNumber: IPPROTO_UDP
        )
    }

    private func connectedSnapshot(
        _ connection: ProcessNetworkConnectionID
    ) -> ProcessNetworkConnectionSnapshot {
        ProcessNetworkConnectionSnapshot(
            activity: .active,
            activeConnections: [connection],
            isComplete: true
        )
    }
}
