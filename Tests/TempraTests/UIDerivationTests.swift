import AppKit
import Combine
import Foundation
import Testing
@testable import Tempra

@Suite("UI derivation")
@MainActor
struct UIDerivationTests {
    @Test("Process scopes preserve search and every sort order")
    func processScopesAndSorting() {
        let items = menuFixtures()
        let expectedOrders: [(ProcessSort, [String])] = [
            (.averageDescending, ["delta", "alpha", "beta"]),
            (.averageAscending, ["alpha", "beta", "delta"]),
            (.currentDescending, ["beta", "delta", "alpha"]),
            (.currentAscending, ["alpha", "delta", "beta"]),
            (.powerDescending, ["beta", "delta", "alpha"]),
            (.powerAscending, ["delta", "beta", "alpha"]),
            (.name, ["alpha", "beta", "delta"]),
        ]

        for (sort, expectedIdentifiers) in expectedOrders {
            let lists = MenuBarItemLists(
                displayItems: items,
                scope: .running,
                processSort: sort,
                searchText: "",
                showsAllRules: false,
                collapsedRuleCount: 2
            )
            #expect(lists.processItems.map(\.bundleIdentifier) == expectedIdentifiers)
        }

        let searched = MenuBarItemLists(
            displayItems: items,
            scope: .rules,
            processSort: .name,
            searchText: "GAMMA",
            showsAllRules: false,
            collapsedRuleCount: 2
        )
        #expect(searched.processItems.map(\.bundleIdentifier) == ["gamma"])

        let alerts = MenuBarItemLists(
            displayItems: items,
            scope: .alerts,
            processSort: .name,
            searchText: "",
            showsAllRules: false,
            collapsedRuleCount: 2
        )
        #expect(alerts.processItems.map(\.bundleIdentifier) == ["beta"])
    }

    @Test("Managed items are derived once with saved-CPU ordering and collapse limits")
    func managedItemOrdering() {
        let collapsed = MenuBarItemLists(
            displayItems: menuFixtures(),
            scope: .running,
            processSort: .name,
            searchText: "",
            showsAllRules: false,
            collapsedRuleCount: 2
        )

        #expect(collapsed.managedItems.map(\.bundleIdentifier) == ["gamma", "beta", "delta"])
        #expect(collapsed.visibleManagedItems.map(\.bundleIdentifier) == ["gamma", "beta"])

        let expanded = MenuBarItemLists(
            displayItems: menuFixtures(),
            scope: .running,
            processSort: .name,
            searchText: "",
            showsAllRules: true,
            collapsedRuleCount: 2
        )
        #expect(expanded.visibleManagedItems.map(\.bundleIdentifier) == [
            "gamma", "beta", "delta",
        ])
    }

    @Test("Icon lookup is lazy, URL-sensitive, and bounded")
    func iconCacheBehavior() {
        var providerCallCount = 0
        let cache = AppIconCache(capacity: 2) { _, _, _ in
            providerCallCount += 1
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        let first = item(
            identifier: "first",
            name: "First",
            applicationURL: URL(fileURLWithPath: "/Applications/First.app"),
            iconCache: cache
        )

        _ = first.icon
        _ = first.icon
        #expect(providerCallCount == 1)

        let movedFirst = item(
            identifier: "first",
            name: "First",
            applicationURL: URL(fileURLWithPath: "/Volumes/Apps/First.app"),
            iconCache: cache
        )
        let second = item(identifier: "second", name: "Second", iconCache: cache)
        let third = item(identifier: "third", name: "Third", iconCache: cache)
        _ = movedFirst.icon
        _ = second.icon
        _ = third.icon

        #expect(providerCallCount == 4)
        #expect(cache.cachedIconCount == 2)

        _ = second.icon
        #expect(providerCallCount == 4)
        _ = movedFirst.icon
        #expect(providerCallCount == 5)

        let override = NSImage(size: NSSize(width: 12, height: 12))
        let overridden = item(
            identifier: "override",
            name: "Override",
            iconOverride: override,
            iconCache: cache
        )
        #expect(overridden.icon === override)
        #expect(providerCallCount == 5)
    }

    @Test("One live monitoring sample publishes one enriched display snapshot")
    func oneProjectionPerMonitoringSample() async throws {
        try await withDefaults { defaults in
            var iconProviderCallCount = 0
            let iconCache = AppIconCache(capacity: 8) { _, _, _ in
                iconProviderCallCount += 1
                return NSImage(size: NSSize(width: 16, height: 16))
            }
            let store = try AppStore(
                persistence: AppPersistence(defaults: defaults),
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: UIDerivationMonitoringService(),
                launchAtLoginController: UIDerivationLaunchAtLoginController(),
                startsMonitoring: false,
                iconCache: iconCache,
                persistenceErrorHandler: { _ in }
            )
            let app = ManagedApp(
                bundleIdentifier: "example.live",
                name: "Live",
                bundleURL: URL(fileURLWithPath: "/Applications/Live.app"),
                processIdentifiers: [],
                cpuPercent: 25,
                isFrontmost: false,
                isHidden: false,
                isPlayingAudio: false,
                isSystemProcess: false,
                status: .normal
            )
            var snapshotPublicationCount = 0
            let displayItemsObservation = store.$displayItems
                .dropFirst()
                .sink { _ in snapshotPublicationCount += 1 }

            store.applyMonitoringSample(
                MonitoringSample(
                    generation: 1,
                    systemCPU: SystemCPUSnapshot(totalPercent: 25),
                    apps: [app],
                    didRefreshApplications: true,
                    powerByIdentifier: [
                        app.bundleIdentifier: ProcessPowerSample(
                            watts: 3.5,
                            joulesPerCPUSecond: 0.14
                        ),
                    ],
                    powerMetricsSupported: true
                ),
                demand: .liveUI
            )

            #expect(snapshotPublicationCount == 1)
            let projected = try #require(store.displayItems.first)
            #expect(projected.cpuPercent == 25)
            #expect(projected.averageCPUPercent == 25)
            #expect(projected.cpuPowerWatts == 3.5)
            #expect(iconProviderCallCount == 0)
            _ = projected.icon
            _ = projected.icon
            #expect(iconProviderCallCount == 1)
            print("UI projection measurement: 1 display snapshot for 1 live monitoring sample")
            withExtendedLifetime(displayItemsObservation) {}

            _ = await store.shutdown()
        }
    }

    @Test("A 1,000-item menu derivation benchmark")
    func menuDerivationBenchmark() throws {
        var items: [AppDisplayItem] = []
        items.reserveCapacity(1_000)
        for index in 0..<1_000 {
            let identifier = "item-\(index)"
            let savedRule = index.isMultiple(of: 3) ? rule(identifier) : nil
            items.append(item(
                identifier: identifier,
                name: String(format: "Process %04d", 999 - index),
                currentCPU: Double(index % 101),
                averageCPU: Double(index % 67),
                power: index.isMultiple(of: 7) ? nil : Double(index % 31),
                savedCPU: Double(index % 43),
                rule: savedRule
            ))
        }
        let clock = ContinuousClock()

        let repeatedStart = clock.now
        var repeatedLists: MenuBarItemLists?
        for _ in 0..<4 {
            repeatedLists = MenuBarItemLists(
                displayItems: items,
                scope: .running,
                processSort: .averageDescending,
                searchText: "process",
                showsAllRules: false,
                collapsedRuleCount: 5
            )
        }
        let repeatedElapsed = repeatedStart.duration(to: clock.now)

        let snapshotStart = clock.now
        let snapshot = MenuBarItemLists(
            displayItems: items,
            scope: .running,
            processSort: .averageDescending,
            searchText: "process",
            showsAllRules: false,
            collapsedRuleCount: 5
        )
        let snapshotElapsed = snapshotStart.duration(to: clock.now)
        let repeated = try #require(repeatedLists)

        #expect(snapshot.processItems.map(\.id) == repeated.processItems.map(\.id))
        #expect(snapshot.managedItems.map(\.id) == repeated.managedItems.map(\.id))
        print(
            "Menu derivation benchmark: 1000 items; repeated \(repeatedElapsed); "
                + "single snapshot \(snapshotElapsed)"
        )
    }

    private func menuFixtures() -> [AppDisplayItem] {
        [
            item(
                identifier: "alpha",
                name: "Alpha",
                currentCPU: 1,
                averageCPU: 10,
                power: nil
            ),
            item(
                identifier: "beta",
                name: "Beta",
                currentCPU: 7,
                averageCPU: 10,
                power: 2,
                savedCPU: 5,
                rule: rule("beta"),
                isAttention: true
            ),
            item(
                identifier: "gamma",
                name: "Third",
                currentCPU: 0,
                averageCPU: 0,
                power: 1,
                savedCPU: 10,
                isRunning: false,
                rule: rule("gamma")
            ),
            item(
                identifier: "delta",
                name: "Delta",
                currentCPU: 4,
                averageCPU: 30,
                power: 1,
                savedCPU: 5,
                rule: rule("delta")
            ),
        ]
    }

    private func item(
        identifier: String,
        name: String,
        applicationURL: URL? = nil,
        iconOverride: NSImage? = nil,
        currentCPU: Double = 0,
        averageCPU: Double = 0,
        power: Double? = nil,
        savedCPU: Double = 0,
        isRunning: Bool = true,
        rule: AppRule? = nil,
        isAttention: Bool = false,
        iconCache: AppIconCache? = nil
    ) -> AppDisplayItem {
        AppDisplayItem(
            bundleIdentifier: identifier,
            name: name,
            applicationURL: applicationURL,
            iconOverride: iconOverride,
            cpuPercent: currentCPU,
            averageCPUPercent: averageCPU,
            estimatedSavedCPUPercent: savedCPU,
            cpuPowerWatts: power,
            isRunning: isRunning,
            isFrontmost: false,
            isHidden: false,
            isPlayingAudio: false,
            status: isRunning ? .normal : .notRunning,
            rule: rule,
            isAttention: isAttention,
            iconCache: iconCache
        )
    }

    private func rule(_ identifier: String) -> AppRule {
        AppRule(
            bundleIdentifier: identifier,
            displayName: identifier.capitalized,
            action: .limit,
            limitPercent: 50
        )
    }

    private func withDefaults(
        _ operation: (UserDefaults) async throws -> Void
    ) async throws {
        let suiteName = "TempraUIDerivationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await operation(defaults)
    }
}

private actor UIDerivationMonitoringService: MonitoringServicing {
    func sample(_ request: MonitoringRequest) -> MonitoringSample {
        MonitoringSample(
            generation: request.generation,
            systemCPU: nil,
            apps: nil,
            didRefreshApplications: false,
            powerByIdentifier: [:],
            powerMetricsSupported: false
        )
    }

    func resetApplicationBaseline() {}
    func resetPowerMetrics() {}
    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {}
    func shutdown() {}
}

@MainActor
private final class UIDerivationLaunchAtLoginController: LaunchAtLoginControlling {
    var isEnabled = false
    var requiresApproval = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}
