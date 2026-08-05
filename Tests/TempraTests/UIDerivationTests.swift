import AppKit
import Combine
import Foundation
import ServiceManagement
import Testing
@testable import Tempra

@Suite("UI derivation")
@MainActor
struct UIDerivationTests {
    @Test("Bundled privileged helper can register from the initial not-found state")
    func privilegedHelperInitialRegistration() async {
        var currentStatus = SMAppService.Status.notFound
        var registrationCount = 0
        var settingsOpenCount = 0
        let manager = PrivilegedHelperManager(
            serviceStatus: { currentStatus },
            bundledServiceIsPresent: { true },
            registerService: {
                registrationCount += 1
                currentStatus = .requiresApproval
            },
            openApprovalSettings: { settingsOpenCount += 1 },
            pingService: {}
        )

        #expect(manager.status == .notRegistered)
        #expect(await manager.requestEnable() == .requiresApproval)
        #expect(registrationCount == 1)
        #expect(settingsOpenCount == 1)
    }

    @Test("Missing privileged helper remains unavailable")
    func missingPrivilegedHelperDoesNotRegister() async {
        var registrationCount = 0
        let manager = PrivilegedHelperManager(
            serviceStatus: { .notFound },
            bundledServiceIsPresent: { false },
            registerService: { registrationCount += 1 },
            openApprovalSettings: {},
            pingService: {}
        )

        #expect(manager.status == .unavailable(
            "Tempra’s privileged helper is missing from this app bundle."
        ))
        #expect(await manager.requestEnable() == manager.status)
        #expect(registrationCount == 0)
    }

    @Test("Denied helper launch opens administrator approval settings")
    func privilegedHelperApprovalRequest() async {
        var settingsOpenCount = 0
        let manager = PrivilegedHelperManager(
            serviceStatus: { .notFound },
            bundledServiceIsPresent: { true },
            registerService: {
                throw NSError(
                    domain: "SMAppServiceErrorDomain",
                    code: Int(kSMErrorLaunchDeniedByUser)
                )
            },
            openApprovalSettings: { settingsOpenCount += 1 },
            pingService: {}
        )

        #expect(await manager.requestEnable() == .requiresApproval)
        #expect(settingsOpenCount == 1)
    }

    @Test("Approved helper failures offer a connection retry")
    func privilegedHelperConnectionFailure() async {
        let manager = PrivilegedHelperManager(
            serviceStatus: { .enabled },
            bundledServiceIsPresent: { true },
            registerService: {},
            openApprovalSettings: {},
            pingService: {
                throw PrivilegedProcessClientError.connectionFailed("The helper exited.")
            }
        )

        let status = await manager.requestEnable()
        #expect(status == .helperUnavailable(
            "Tempra could not connect to its privileged helper: The helper exited."
        ))
        #expect(status.actionTitle == "Retry Connection")
        #expect(status.message?.hasPrefix("Administrator access is enabled") == true)
        #expect(PrivilegedControlStatus.unavailable("Missing").actionTitle == nil)
    }

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
                includesBackgroundAndSystemProcesses: true,
                scope: .running,
                processSort: sort,
                searchText: ""
            )
            #expect(lists.processItems.map(\.bundleIdentifier) == expectedIdentifiers)
        }

        let searched = MenuBarItemLists(
            displayItems: items,
            includesBackgroundAndSystemProcesses: true,
            scope: .rules,
            processSort: .name,
            searchText: "GAMMA"
        )
        #expect(searched.processItems.map(\.bundleIdentifier) == ["gamma"])

        let alerts = MenuBarItemLists(
            displayItems: items,
            includesBackgroundAndSystemProcesses: true,
            scope: .alerts,
            processSort: .name,
            searchText: ""
        )
        #expect(alerts.processItems.map(\.bundleIdentifier) == ["beta"])
    }

    @Test("Menu presentation retains the selected process sort")
    func processSortSelectionPersistence() {
        let presentation = MenuPanelPresentation()

        #expect(presentation.processSort == .averageDescending)
        presentation.processSort = .currentDescending
        presentation.closeInspector()

        #expect(presentation.processSort == .currentDescending)
    }

    @Test("Administrator access onboarding can be shown and dismissed")
    func privilegedAccessOnboardingPresentation() {
        let presentation = MenuPanelPresentation()

        #expect(!presentation.showsPrivilegedAccessOnboarding)
        presentation.showPrivilegedAccessOnboarding()
        #expect(presentation.showsPrivilegedAccessOnboarding)
        presentation.dismissPrivilegedAccessOnboarding()
        #expect(!presentation.showsPrivilegedAccessOnboarding)
    }

    @Test("Managed items keep every rule in stable name order as live savings change")
    func managedItemOrdering() {
        let initial = MenuBarItemLists(
            displayItems: menuFixtures(),
            includesBackgroundAndSystemProcesses: true,
            scope: .running,
            processSort: .name,
            searchText: ""
        )
        #expect(initial.managedItems.map(\.bundleIdentifier) == ["beta", "delta", "gamma"])

        let changedSavings = MenuBarItemLists(
            displayItems: menuFixtures(
                betaSavedCPU: 50,
                gammaSavedCPU: 0,
                deltaSavedCPU: 25
            ),
            includesBackgroundAndSystemProcesses: true,
            scope: .running,
            processSort: .name,
            searchText: ""
        )
        #expect(changedSavings.managedItems.map(\.bundleIdentifier) == [
            "beta", "delta", "gamma",
        ])
    }

    @Test("Background and system processes stay hidden from Running when disabled")
    func backgroundAndSystemProcessVisibility() {
        let backgroundIdentifier = BackgroundProcessPolicy.userOwnedIdentifier(
            command: "/Users/example/wine64-preloader",
            pid: 10
        )
        let items = [
            item(identifier: "ordinary", name: "Ordinary"),
            item(
                identifier: "com.apple.dock",
                name: "Dock",
                isSystemProcess: true,
                rule: rule("com.apple.dock")
            ),
            item(
                identifier: backgroundIdentifier,
                name: "Game.exe",
                rule: rule(backgroundIdentifier)
            ),
            item(
                identifier: "background-agent",
                name: "Background Agent",
                isBackgroundProcess: true
            ),
        ]

        let hidden = MenuBarItemLists(
            displayItems: items,
            includesBackgroundAndSystemProcesses: false,
            scope: .running,
            processSort: .name,
            searchText: ""
        )
        #expect(hidden.processItems.map(\.bundleIdentifier) == ["ordinary"])
        #expect(Set(hidden.managedItems.map(\.bundleIdentifier)) == [
            "com.apple.dock", backgroundIdentifier,
        ])

        let visible = MenuBarItemLists(
            displayItems: items,
            includesBackgroundAndSystemProcesses: true,
            scope: .running,
            processSort: .name,
            searchText: ""
        )
        #expect(visible.processItems.map(\.bundleIdentifier) == [
            "background-agent", "com.apple.dock", backgroundIdentifier, "ordinary",
        ])

        let rules = MenuBarItemLists(
            displayItems: items,
            includesBackgroundAndSystemProcesses: false,
            scope: .rules,
            processSort: .name,
            searchText: ""
        )
        #expect(Set(rules.processItems.map(\.bundleIdentifier)) == [
            "com.apple.dock", backgroundIdentifier,
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
                processIdentifiers: [11, 12],
                launchedAt: Date(timeIntervalSince1970: 1_000),
                cpuPercent: 25,
                residentMemoryBytes: 512 * 1_024 * 1_024,
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
            #expect(projected.residentMemoryBytes == 512 * 1_024 * 1_024)
            #expect(projected.processCount == 2)
            #expect(projected.launchedAt == Date(timeIntervalSince1970: 1_000))
            #expect(store.cpuHistorySamples.last?.estimatedSavedCPUPercent == 0)
            #expect(store.cpuHistorySamples.last?.hasEstimatedSavedCPUMeasurement == true)
            #expect(iconProviderCallCount == 0)
            _ = projected.icon
            _ = projected.icon
            #expect(iconProviderCallCount == 1)
            print("UI projection measurement: 1 display snapshot for 1 live monitoring sample")
            withExtendedLifetime(displayItemsObservation) {}

            _ = await store.shutdown()
        }
    }

    @Test("Activity inspector selection stays separate from the rule editor")
    func activityInspectorSelection() {
        let presentation = MenuPanelPresentation()

        presentation.showActivity(
            bundleIdentifier: "example.app",
            anchorKey: "process:example.app",
            localMidY: 120
        )
        #expect(presentation.selection?.inspector == .activity)

        presentation.select(
            bundleIdentifier: "example.app",
            anchorKey: "process:example.app",
            localMidY: 120
        )
        #expect(presentation.selection?.inspector == .rule)

        presentation.select(
            bundleIdentifier: "example.app",
            anchorKey: "process:example.app",
            localMidY: 120
        )
        #expect(presentation.selection == nil)
    }

    @Test("Only ordinary running apps expose macOS application commands")
    func processControlAvailability() {
        let ordinary = item(identifier: "ordinary", name: "Ordinary")
        let standalone = item(
            identifier: BackgroundProcessPolicy.userOwnedIdentifier(
                command: "/Users/example/wine64-preloader",
                pid: 10
            ),
            name: "Game.exe"
        )
        let protected = item(
            identifier: "protected",
            name: "Protected",
            isSystemProcess: true
        )
        let stopped = item(
            identifier: "stopped",
            name: "Stopped",
            isRunning: false
        )
        let windowServer = item(
            identifier: BackgroundProcessPolicy.identifier(
                command: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                pid: 100
            ),
            name: "WindowServer",
            isSystemProcess: true
        )
        let soundSource = item(
            identifier: SoundSourceCompatibilityPolicy.primaryBundleIdentifier,
            name: "SoundSource"
        )
        let futureSoundSourceHelper = item(
            identifier: "com.rogueamoeba.FutureSoundSourceHost",
            name: "SoundSource Helper",
            applicationURL: URL(
                fileURLWithPath: "/Applications/SoundSource.app/Contents/XPCServices/"
                    + "FutureSoundSourceHost.xpc"
            )
        )

        #expect(ordinary.canControlApplication)
        #expect(standalone.isStandaloneProcess)
        #expect(!standalone.canControlApplication)
        #expect(!protected.canControlApplication)
        #expect(!stopped.canControlApplication)
        #expect(!windowServer.canLimitCPU)
        #expect(windowServer.canQuitProcess)
        #expect(soundSource.isSoundSourceComponent)
        #expect(!soundSource.canManageProcess)
        #expect(!soundSource.canControlApplication)
        #expect(!soundSource.canQuitProcess)
        #expect(!soundSource.canLimitCPU)
        #expect(futureSoundSourceHelper.isSoundSourceComponent)
        #expect(!futureSoundSourceHelper.canManageProcess)
        #expect(ordinary.residentMemoryText == "—")
    }

    @Test("Essential system process inclusion persists across recurring UI samples")
    func essentialSystemProcessInclusionPersists() async throws {
        try await withDefaults { defaults in
            let monitoringService = UIDerivationMonitoringService()
            let store = try AppStore(
                persistence: AppPersistence(defaults: defaults),
                managementCoordinator: ProcessManagementCoordinator(),
                monitoringService: monitoringService,
                launchAtLoginController: UIDerivationLaunchAtLoginController(),
                startsMonitoring: false,
                persistenceErrorHandler: { _ in }
            )

            store.setPresentationActive(true)
            var requests = try await waitForInclusionRequests(
                1,
                from: monitoringService
            )
            #expect(requests.last == false)

            store.setIncludesEssentialSystemProcesses(true)
            requests = try await waitForInclusionRequests(
                3,
                from: monitoringService
            )

            #expect(Array(requests.suffix(2)) == [true, true])
            #expect(store.preferences.includesEssentialSystemProcesses)
            #expect(try AppPersistence(defaults: defaults)
                .loadPreferences().includesEssentialSystemProcesses)

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
                includesBackgroundAndSystemProcesses: true,
                scope: .running,
                processSort: .averageDescending,
                searchText: "process"
            )
        }
        let repeatedElapsed = repeatedStart.duration(to: clock.now)

        let snapshotStart = clock.now
        let snapshot = MenuBarItemLists(
            displayItems: items,
            includesBackgroundAndSystemProcesses: true,
            scope: .running,
            processSort: .averageDescending,
            searchText: "process"
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

    private func menuFixtures(
        betaSavedCPU: Double = 5,
        gammaSavedCPU: Double = 10,
        deltaSavedCPU: Double = 5
    ) -> [AppDisplayItem] {
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
                savedCPU: betaSavedCPU,
                rule: rule("beta"),
                isAttention: true
            ),
            item(
                identifier: "gamma",
                name: "Third",
                currentCPU: 0,
                averageCPU: 0,
                power: 1,
                savedCPU: gammaSavedCPU,
                isRunning: false,
                rule: rule("gamma")
            ),
            item(
                identifier: "delta",
                name: "Delta",
                currentCPU: 4,
                averageCPU: 30,
                power: 1,
                savedCPU: deltaSavedCPU,
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
        isBackgroundProcess: Bool = false,
        isSystemProcess: Bool = false,
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
            isBackgroundProcess: isBackgroundProcess,
            isSystemProcess: isSystemProcess,
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

    private func waitForInclusionRequests(
        _ expectedCount: Int,
        from service: UIDerivationMonitoringService
    ) async throws -> [Bool] {
        for _ in 0..<150 {
            let requests = await service.inclusionRequests()
            if requests.count >= expectedCount {
                return requests
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw InclusionRequestTimeout()
    }
}

private struct InclusionRequestTimeout: Error {}

private actor UIDerivationMonitoringService: MonitoringServicing {
    private var recordedInclusionRequests: [Bool] = []

    func sample(_ request: MonitoringRequest) -> MonitoringSample {
        recordedInclusionRequests.append(request.includesEssentialSystemProcesses)
        return MonitoringSample(
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

    func inclusionRequests() -> [Bool] {
        recordedInclusionRequests
    }
}

@MainActor
private final class UIDerivationLaunchAtLoginController: LaunchAtLoginControlling {
    var isEnabled = false
    var requiresApproval = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}
