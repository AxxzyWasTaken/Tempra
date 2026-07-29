import Foundation
import Testing
@testable import Tempra

@Suite("App history store")
@MainActor
struct AppHistoryStoreTests {
    private let referenceDate = Date(timeIntervalSinceReferenceDate: 2_000_000)

    @Test("Initialization sorts history and retains the exact cutoff")
    func initializationSortsAndTrims() throws {
        try withDefaults { defaults in
            let cutoff = referenceDate.addingTimeInterval(-24 * 60 * 60)
            let store = AppHistoryStore(
                persistence: AppPersistence(defaults: defaults),
                activityEvents: [],
                cpuHistorySamples: [
                    sample(at: referenceDate.addingTimeInterval(-15)),
                    sample(at: cutoff.addingTimeInterval(-0.001)),
                    sample(at: cutoff),
                ],
                now: referenceDate
            )

            #expect(store.cpuHistorySamples.map(\.date) == [
                cutoff,
                referenceDate.addingTimeInterval(-15),
            ])
        }
    }

    @Test("An accepted out-of-order sample is inserted in date order")
    func acceptedOutOfOrderSampleIsInserted() throws {
        try withDefaults { defaults in
            let latestDate = referenceDate.addingTimeInterval(60)
            let store = AppHistoryStore(
                persistence: AppPersistence(defaults: defaults),
                activityEvents: [],
                cpuHistorySamples: [sample(at: latestDate), sample(at: referenceDate)],
                now: latestDate
            )
            let insertedDate = referenceDate.addingTimeInterval(15)

            let result = try #require(try store.recordCPUHistory(
                systemCPU: systemCPU,
                estimatedSavedSystemPercent: 4,
                interventionCount: 5,
                now: insertedDate
            ))

            #expect(result.map(\.date) == [referenceDate, insertedDate, latestDate])
        }
    }

    @Test("Backward clock movement does not accept a sample")
    func backwardClockMovementIsRejected() throws {
        try withDefaults { defaults in
            let latestDate = referenceDate.addingTimeInterval(15)
            let initialSamples = [sample(at: referenceDate), sample(at: latestDate)]
            let store = AppHistoryStore(
                persistence: AppPersistence(defaults: defaults),
                activityEvents: [],
                cpuHistorySamples: initialSamples,
                now: latestDate
            )

            let result = try store.recordCPUHistory(
                systemCPU: systemCPU,
                estimatedSavedSystemPercent: 4,
                interventionCount: 5,
                now: referenceDate.addingTimeInterval(5)
            )

            #expect(result == nil)
            #expect(store.cpuHistorySamples == initialSamples)
            #expect(defaults.object(forKey: "temper.cpuHistory.v3") == nil)
        }
    }

    @Test("A persistence failure restores samples and sampling dates")
    func persistenceFailureRollsBack() throws {
        try withDefaults { defaults in
            var allowsWrites = true
            let persistence = AppPersistence(defaults: defaults, writer: { value, key in
                if allowsWrites {
                    defaults.set(value, forKey: key)
                }
            })
            let store = AppHistoryStore(
                persistence: persistence,
                activityEvents: [],
                cpuHistorySamples: [],
                now: referenceDate
            )
            _ = try store.recordCPUHistory(
                systemCPU: systemCPU,
                estimatedSavedSystemPercent: 4,
                interventionCount: 5,
                now: referenceDate
            )
            _ = try store.recordCPUHistory(
                systemCPU: systemCPU,
                estimatedSavedSystemPercent: 4,
                interventionCount: 5,
                now: referenceDate.addingTimeInterval(15)
            )
            let samplesBeforeFailure = store.cpuHistorySamples
            allowsWrites = false

            #expect(throws: AppPersistenceError.self) {
                _ = try store.recordCPUHistory(
                    systemCPU: systemCPU,
                    estimatedSavedSystemPercent: 4,
                    interventionCount: 5,
                    now: referenceDate.addingTimeInterval(60)
                )
            }
            #expect(store.cpuHistorySamples == samplesBeforeFailure)

            allowsWrites = true
            let retry = try #require(try store.recordCPUHistory(
                systemCPU: systemCPU,
                estimatedSavedSystemPercent: 4,
                interventionCount: 5,
                now: referenceDate.addingTimeInterval(60)
            ))
            #expect(retry.count == samplesBeforeFailure.count + 1)
            #expect(try persistence.loadCPUHistory() == retry)
        }
    }

    @Test("A full day retains both cutoff endpoints and no extra samples")
    func maximumRetainedHistory() throws {
        try withDefaults { defaults in
            let firstDate = referenceDate.addingTimeInterval(-24 * 60 * 60)
            let initialSamples = (0...5_760).map { index in
                sample(at: firstDate.addingTimeInterval(TimeInterval(index * 15)))
            }
            let store = AppHistoryStore(
                persistence: AppPersistence(defaults: defaults),
                activityEvents: [],
                cpuHistorySamples: initialSamples,
                now: referenceDate
            )

            #expect(store.cpuHistorySamples.count == 5_761)
            let result = try #require(try store.recordCPUHistory(
                systemCPU: systemCPU,
                estimatedSavedSystemPercent: 4,
                interventionCount: 5,
                now: referenceDate.addingTimeInterval(15)
            ))

            #expect(result.count == 5_761)
            #expect(result.first?.date == firstDate.addingTimeInterval(15))
            #expect(result.last?.date == referenceDate.addingTimeInterval(15))
        }
    }

    @Test("A 5,760-sample accepted-history benchmark")
    func acceptedHistoryBenchmark() throws {
        try withDefaults { defaults in
            let firstDate = referenceDate.addingTimeInterval(-86_385)
            let initialSamples = (0..<5_760).map { index in
                sample(at: firstDate.addingTimeInterval(TimeInterval(index * 15)))
            }
            let store = AppHistoryStore(
                persistence: AppPersistence(defaults: defaults),
                activityEvents: [],
                cpuHistorySamples: initialSamples,
                now: referenceDate
            )
            _ = try store.recordCPUHistory(
                systemCPU: systemCPU,
                estimatedSavedSystemPercent: 4,
                interventionCount: 5,
                now: referenceDate.addingTimeInterval(15)
            )
            let samplesBeforeBenchmark = store.cpuHistorySamples
            let acceptedDate = referenceDate.addingTimeInterval(30)
            let acceptedSample = sample(at: acceptedDate)
            let clock = ContinuousClock()

            let legacyStart = clock.now
            let legacy = legacyAcceptedHistory(
                samples: samplesBeforeBenchmark,
                sample: acceptedSample,
                now: acceptedDate
            )
            let legacyElapsed = legacyStart.duration(to: clock.now)

            let optimizedStart = clock.now
            let optimized = try #require(try store.recordCPUHistory(
                systemCPU: systemCPU,
                estimatedSavedSystemPercent: 4,
                interventionCount: 5,
                now: acceptedDate
            ))
            let optimizedElapsed = optimizedStart.duration(to: clock.now)

            #expect(optimized == legacy.samples)
            #expect(legacy.rollbackCount == samplesBeforeBenchmark.count)
            print(
                "CPU history acceptance benchmark: \(optimized.count) samples; "
                    + "legacy \(legacyElapsed); ordered \(optimizedElapsed)"
            )
        }
    }

    private var systemCPU: SystemCPUSnapshot {
        SystemCPUSnapshot(
            totalPercent: 1,
            performancePercent: 2,
            efficiencyPercent: 3,
            cpuTemperatureCelsius: 70,
            thermalPressure: .nominal
        )
    }

    private func sample(at date: Date) -> CPUHistorySample {
        CPUHistorySample(
            date: date,
            systemCPUPercent: 1,
            performanceCPUPercent: 2,
            efficiencyCPUPercent: 3,
            estimatedSavedCPUPercent: 4,
            cpuTemperatureCelsius: 70,
            thermalPressure: .nominal,
            interventionCount: 5
        )
    }

    private func legacyAcceptedHistory(
        samples: [CPUHistorySample],
        sample: CPUHistorySample,
        now: Date
    ) -> (samples: [CPUHistorySample], rollbackCount: Int) {
        let rollbackSamples = samples
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        var updatedSamples = samples
        updatedSamples.append(sample)
        updatedSamples = updatedSamples
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
        return (updatedSamples, rollbackSamples.count)
    }

    private func withDefaults(
        _ operation: (UserDefaults) throws -> Void
    ) throws {
        let suiteName = "TempraHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try operation(defaults)
    }
}
