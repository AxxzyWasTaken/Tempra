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
                appCPUHistorySamples: [
                    appSample(
                        identifier: "example.recent",
                        at: referenceDate.addingTimeInterval(-15)
                    ),
                    appSample(
                        identifier: "example.expired",
                        at: cutoff.addingTimeInterval(-0.001)
                    ),
                    appSample(identifier: "example.cutoff", at: cutoff)
                ],
                now: referenceDate
            )

            #expect(store.cpuHistorySamples.map(\.date) == [
                cutoff,
                referenceDate.addingTimeInterval(-15),
            ])
            #expect(store.appCPUHistorySamples.map(\.bundleIdentifier) == [
                "example.cutoff",
                "example.recent"
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

    @Test("Lightweight samples preserve absent application metrics")
    func lightweightSampleRoundTrips() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)
            let store = AppHistoryStore(
                persistence: persistence,
                activityEvents: [],
                cpuHistorySamples: [],
                now: referenceDate
            )
            var lightweightCPU = systemCPU
            lightweightCPU.cpuTemperatureCelsius = nil

            let samples = try #require(try store.recordCPUHistory(
                systemCPU: lightweightCPU,
                estimatedSavedSystemPercent: nil,
                interventionCount: 5,
                now: referenceDate
            ))
            let sample = try #require(samples.first)

            #expect(sample.systemCPUPercent == lightweightCPU.totalPercent)
            #expect(sample.estimatedSavedCPUPercent == 0)
            #expect(!sample.hasEstimatedSavedCPUMeasurement)
            #expect(sample.cpuTemperatureCelsius == nil)
            #expect(try persistence.loadCPUHistory() == samples)
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

    @Test("Per-app history prioritizes the focused and managed applications")
    func perAppHistoryPrioritizesFocusedAndManagedApps() throws {
        try withDefaults { defaults in
            let persistence = AppPersistence(defaults: defaults)
            let store = AppHistoryStore(
                persistence: persistence,
                activityEvents: [],
                cpuHistorySamples: [],
                now: referenceDate
            )
            let apps = (0..<30).map { index in
                managedApp(
                    identifier: "example.\(index)",
                    cpuPercent: Double(index)
                )
            }

            let samples = try #require(try store.recordAppCPUHistory(
                apps: apps,
                estimatedSavedCPUByIdentifier: ["example.0": 2],
                prioritizedBundleIdentifiers: ["example.1"],
                focusedBundleIdentifier: "example.0",
                now: referenceDate
            ))

            #expect(samples.count == 24)
            #expect(samples.contains { $0.bundleIdentifier == "example.0" })
            #expect(samples.contains { $0.bundleIdentifier == "example.1" })
            #expect(samples.first { $0.bundleIdentifier == "example.0" }?
                .estimatedSavedCPUPercent == 2)
            #expect(try persistence.loadAppCPUHistory() == samples)
        }
    }

    @Test("Per-app history uses a bounded sampling cadence")
    func perAppHistoryUsesBoundedCadence() throws {
        try withDefaults { defaults in
            let store = AppHistoryStore(
                persistence: AppPersistence(defaults: defaults),
                activityEvents: [],
                cpuHistorySamples: [],
                now: referenceDate
            )
            let apps = [managedApp(identifier: "example.app", cpuPercent: 12)]

            _ = try store.recordAppCPUHistory(
                apps: apps,
                estimatedSavedCPUByIdentifier: [:],
                prioritizedBundleIdentifiers: [],
                focusedBundleIdentifier: nil,
                now: referenceDate
            )
            let early = try store.recordAppCPUHistory(
                apps: apps,
                estimatedSavedCPUByIdentifier: [:],
                prioritizedBundleIdentifiers: [],
                focusedBundleIdentifier: nil,
                now: referenceDate.addingTimeInterval(29)
            )
            let accepted = try #require(try store.recordAppCPUHistory(
                apps: apps,
                estimatedSavedCPUByIdentifier: [:],
                prioritizedBundleIdentifiers: [],
                focusedBundleIdentifier: nil,
                now: referenceDate.addingTimeInterval(30)
            ))

            #expect(early == nil)
            #expect(accepted.count == 2)
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

    private func managedApp(
        identifier: String,
        cpuPercent: Double
    ) -> ManagedApp {
        ManagedApp(
            bundleIdentifier: identifier,
            name: identifier,
            bundleURL: nil,
            processIdentifiers: [],
            cpuPercent: cpuPercent,
            isFrontmost: false,
            isHidden: true,
            isPlayingAudio: false,
            isSystemProcess: false,
            status: .normal
        )
    }

    private func appSample(
        identifier: String,
        at date: Date
    ) -> AppCPUHistorySample {
        AppCPUHistorySample(
            bundleIdentifier: identifier,
            date: date,
            cpuPercent: 1,
            estimatedSavedCPUPercent: 2
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
