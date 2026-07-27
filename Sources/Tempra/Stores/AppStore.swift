import AppKit
import Combine
import Foundation
import OSLog

private let monitoringLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "io.github.temperapp.Temper",
    category: "Monitoring"
)

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published private(set) var apps: [ManagedApp] = []
    @Published private(set) var rules: [String: AppRule] = [:]
    @Published private(set) var preferences = AppPreferences()
    @Published private(set) var suspensions: [String: RuleSuspension] = [:]
    @Published private(set) var activityEvents: [ActivityEvent] = []
    @Published private(set) var cpuHistorySamples: [CPUHistorySample] = []
    @Published private(set) var systemCPU = SystemCPUSnapshot()
    @Published private(set) var attentionIdentifiers: Set<String> = []
    @Published private(set) var pendingHighCPUAlert: HighCPUAlert?
    @Published private(set) var isEnabled: Bool
    @Published private(set) var launchAtLoginError: String?
    var displayItems: [AppDisplayItem] = []

    let managementCoordinator: ProcessManagementCoordinator
    private let launchAtLoginController: any LaunchAtLoginControlling
    private let persistence: AppPersistence
    private let monitoringService: any MonitoringServicing
    private lazy var historyStore = AppHistoryStore(persistence: persistence)
    lazy var managementLedger = ManagementLedger(
        defaults: persistence.defaults,
        activityEvents: activityEvents
    )
    private lazy var monitoringCoordinator = MonitoringCoordinator(
        service: monitoringService
    ) { [weak self] sample in self?.handleMonitoringSample(sample) }
    private let workspaceEventMonitor = WorkspaceEventMonitor()
    private var highCPUDetector = HighCPUDetector()
    var runtimeMetrics = RuntimeMetrics()
    private var isPresentationActive = false
    private var hasShutDown = false

    convenience init() {
        self.init(
            persistence: AppPersistence(),
            managementCoordinator: ProcessManagementCoordinator(),
            monitoringService: MonitoringService(),
            launchAtLoginController: LaunchAtLoginController(),
            startsMonitoring: true
        )
    }

    init(
        persistence: AppPersistence,
        managementCoordinator: ProcessManagementCoordinator,
        monitoringService: any MonitoringServicing,
        launchAtLoginController: any LaunchAtLoginControlling,
        startsMonitoring: Bool
    ) {
        self.persistence = persistence
        self.managementCoordinator = managementCoordinator
        self.monitoringService = monitoringService
        self.launchAtLoginController = launchAtLoginController
        isEnabled = persistence.loadEnabled()
        loadRules()
        loadPreferences()
        loadSuspensions()
        activityEvents = historyStore.activityEvents
        cpuHistorySamples = historyStore.cpuHistorySamples
        managementLedger.startHeartbeat()

        preferences.launchAtLogin = launchAtLoginController.isEnabled
        if launchAtLoginController.requiresApproval {
            launchAtLoginError = "Approve Tempra in System Settings › General › Login Items."
        }
        persistPreferences()
        managementCoordinator.start(
            eventHandler: { [weak self] event in
                self?.handleControllerEvent(event)
            },
            stateHandler: { [weak self] statuses, savedCPU in
                self?.applyManagementState(statuses: statuses, savedCPU: savedCPU)
            }
        )

        if startsMonitoring {
            workspaceEventMonitor.start { [weak self] in
                self?.refresh()
            }
            configureMonitoringDemand(refreshImmediately: false)
            refresh()
        }
    }

    func save(_ rule: AppRule) {
        guard !BackgroundProcessPolicy.isMonitorOnlyIdentifier(rule.bundleIdentifier),
              apps.first(where: { $0.bundleIdentifier == rule.bundleIdentifier })?
                .isSystemProcess != true else { return }

        var normalized = rule
        normalized.limitPercent = min(max(1, normalized.limitPercent), maximumLimit)
        if normalized.action == .pause {
            normalized.runOnEfficiencyCores = false
        }
        normalized.updatedAt = Date()
        if normalized.applicationURL == nil {
            normalized.applicationURL = apps.first {
                $0.bundleIdentifier == normalized.bundleIdentifier
            }?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalized.bundleIdentifier)
        }

        if !normalized.hasBehavior {
            removeRule(bundleIdentifier: normalized.bundleIdentifier)
            return
        }

        rules[normalized.bundleIdentifier] = normalized
        persistRules()
        recordActivity(
            bundleIdentifier: normalized.bundleIdentifier,
            kind: normalized.isEnabled ? .ruleSaved : .ruleDisabled,
            detail: normalized.summary
        )
        applyRulesToCurrentApps()
    }

    func applyQuickRule(
        bundleIdentifier: String,
        displayName: String,
        applicationURL: URL?,
        action: RuleAction,
        limitPercent: Double = 50,
        delaySeconds: TimeInterval
    ) {
        var rule = rules[bundleIdentifier] ?? AppRule(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            applicationURL: applicationURL
        )
        rule.displayName = displayName
        rule.applicationURL = applicationURL ?? rule.applicationURL
        rule.action = action
        if action == .pause {
            rule.runOnEfficiencyCores = false
        }
        rule.limitPercent = limitPercent
        rule.delaySeconds = delaySeconds
        rule.isEnabled = true
        save(rule)
    }

    func setEfficiencyCoreScheduling(
        bundleIdentifier: String,
        displayName: String,
        applicationURL: URL?,
        enabled: Bool,
        delaySeconds: TimeInterval = 0
    ) {
        var rule = rules[bundleIdentifier] ?? AppRule(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            applicationURL: applicationURL
        )
        rule.displayName = displayName
        rule.applicationURL = applicationURL ?? rule.applicationURL
        rule.runOnEfficiencyCores = enabled
        if enabled, rule.action == .pause {
            rule.action = .none
        }
        rule.delaySeconds = delaySeconds
        rule.isEnabled = true
        save(rule)
    }

    func setRuleEnabled(bundleIdentifier: String, enabled: Bool) {
        guard var rule = rules[bundleIdentifier] else { return }
        rule.isEnabled = enabled
        save(rule)
    }

    func removeRule(bundleIdentifier: String) {
        guard rules[bundleIdentifier] != nil else { return }
        recordActivity(
            bundleIdentifier: bundleIdentifier,
            kind: .ruleRemoved,
            detail: "Tempra will no longer manage this app."
        )
        rules.removeValue(forKey: bundleIdentifier)
        suspensions.removeValue(forKey: bundleIdentifier)
        persistRules()
        persistSuspensions()
        applyRulesToCurrentApps()
    }

    func snooze(bundleIdentifier: String, for duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        suspensions[bundleIdentifier] = RuleSuspension(
            bundleIdentifier: bundleIdentifier,
            until: until
        )
        persistSuspensions()
        recordActivity(
            bundleIdentifier: bundleIdentifier,
            kind: .snoozed,
            detail: "Until \(until.formatted(date: .omitted, time: .shortened))"
        )
        applyRulesToCurrentApps()
    }

    func endSnooze(bundleIdentifier: String) {
        guard suspensions.removeValue(forKey: bundleIdentifier) != nil else { return }
        persistSuspensions()
        applyRulesToCurrentApps()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        persistence.saveEnabled(enabled)
        applyRulesToCurrentApps()
    }

    func setHighCPUAlertsEnabled(_ enabled: Bool) {
        preferences.highCPUAlertsEnabled = enabled
        if !enabled {
            pendingHighCPUAlert = nil
        }
        persistPreferences()
    }

    func setHighCPUThreshold(_ threshold: Double) {
        preferences.highCPUThreshold = min(max(25, threshold), maximumLimit)
        persistPreferences()
    }

    func setHighCPUDuration(_ duration: TimeInterval) {
        preferences.highCPUDuration = duration
        persistPreferences()
    }

    func setNotificationCooldown(_ duration: TimeInterval) {
        preferences.notificationCooldown = duration
        persistPreferences()
    }

    func dismissHighCPUAlert() {
        pendingHighCPUAlert = nil
    }

    func limitPendingHighCPUAlert() {
        guard let alert = pendingHighCPUAlert else { return }
        pendingHighCPUAlert = nil
        applyQuickRule(
            bundleIdentifier: alert.bundleIdentifier,
            displayName: alert.displayName,
            applicationURL: alert.applicationURL,
            action: .limit,
            limitPercent: 50,
            delaySeconds: 0
        )
    }

    func ignoreHighCPUAlerts(for bundleIdentifier: String) {
        preferences.ignoredHighCPUAlertBundleIdentifiers.insert(bundleIdentifier)
        if pendingHighCPUAlert?.bundleIdentifier == bundleIdentifier {
            pendingHighCPUAlert = nil
        }
        persistPreferences()
    }

    func clearIgnoredHighCPUAlerts() {
        preferences.ignoredHighCPUAlertBundleIdentifiers.removeAll()
        persistPreferences()
    }

    @discardableResult
    func createManagementProfile(named name: String) -> UUID? {
        let normalizedName = profileName(from: name)
        guard !normalizedName.isEmpty else { return nil }

        let profile = ManagementProfile(name: normalizedName)
        preferences.profiles.append(profile)
        preferences.activeProfileID = profile.id
        persistPreferences()
        applyRulesToCurrentApps()
        return profile.id
    }

    func renameManagementProfile(id: UUID, to name: String) {
        let normalizedName = profileName(from: name)
        guard !normalizedName.isEmpty,
              let index = preferences.profiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        preferences.profiles[index].name = normalizedName
        persistPreferences()
    }

    func updateManagementProfile(
        id: UUID,
        update: (inout ManagementProfile) -> Void
    ) {
        guard let index = preferences.profiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&preferences.profiles[index])
        preferences.profiles[index].name = profileName(from: preferences.profiles[index].name)
        preferences.profiles[index].limitPercent = min(
            max(1, preferences.profiles[index].limitPercent),
            maximumLimit
        )
        preferences.profiles[index].delaySeconds = min(
            max(0, preferences.profiles[index].delaySeconds),
            5 * 60
        )
        persistPreferences()
        if preferences.activeProfileID == id {
            applyRulesToCurrentApps()
        }
    }

    func deleteManagementProfile(id: UUID) {
        guard preferences.profiles.contains(where: { $0.id == id }) else { return }
        preferences.profiles.removeAll { $0.id == id }
        if preferences.activeProfileID == id {
            preferences.activeProfileID = nil
        }
        persistPreferences()
        applyRulesToCurrentApps()
    }

    func setActiveManagementProfile(_ id: UUID?) {
        guard id == nil || preferences.profiles.contains(where: { $0.id == id }) else {
            return
        }
        preferences.activeProfileID = id
        persistPreferences()
        applyRulesToCurrentApps()
    }

    func setAppearance(_ appearance: AppAppearance) {
        preferences.appearance = appearance
        persistPreferences()
    }

    func setIncludesEssentialSystemProcesses(_ includes: Bool) {
        preferences.includesEssentialSystemProcesses = includes
        persistPreferences()
        refresh()
    }

    func setContinuousMonitoringEnabled(_ enabled: Bool) {
        guard preferences.continuousMonitoringEnabled != enabled else { return }
        preferences.continuousMonitoringEnabled = enabled
        persistPreferences()
        configureMonitoringDemand(refreshImmediately: true)
    }

    func setPresentationActive(_ isActive: Bool) {
        guard isPresentationActive != isActive else { return }
        isPresentationActive = isActive
        configureMonitoringDemand(refreshImmediately: isActive)
    }

    func setShowsCPUHistoryGraph(_ isVisible: Bool) {
        preferences.showsCPUHistoryGraph = isVisible
        persistPreferences()
    }

    func setShowsCPUUsageInMenuBar(_ isVisible: Bool) {
        preferences.showsCPUUsageInMenuBar = isVisible
        persistPreferences()
        configureMonitoringDemand(refreshImmediately: true)
    }

    func setHistoryRange(_ range: CPUHistoryRange) {
        preferences.historyRange = range
        persistPreferences()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            try launchAtLoginController.setEnabled(enabled)
            preferences.launchAtLogin = launchAtLoginController.isEnabled
            if enabled, launchAtLoginController.requiresApproval {
                launchAtLoginError = "Approve Tempra in System Settings › General › Login Items."
            }
        } catch {
            preferences.launchAtLogin = launchAtLoginController.isEnabled
            launchAtLoginError = error.localizedDescription
        }
        persistPreferences()
    }

    private var monitoringDemand: MonitoringDemand {
        MonitoringDemand.resolve(
            isPresentationActive: isPresentationActive,
            isContinuousMonitoringEnabled: preferences.continuousMonitoringEnabled,
            showsCPUUsageInMenuBar: preferences.showsCPUUsageInMenuBar
        )
    }

    private func configureMonitoringDemand(refreshImmediately: Bool) {
        let demand = monitoringDemand
        let previousDemand = monitoringCoordinator.demand

        if !demand.samplesApplications {
            runtimeMetrics.resetApplicationMetrics()
            highCPUDetector.reset()
            attentionIdentifiers.removeAll()
            pendingHighCPUAlert = nil
            historyStore.persistCPUHistory()
        }
        monitoringCoordinator.configure(
            demand: demand,
            refreshImmediately: refreshImmediately,
            includesEssentialSystemProcesses: preferences.includesEssentialSystemProcesses
        )

        if previousDemand != demand {
            monitoringLogger.debug(
                "Monitoring mode changed from \(String(describing: previousDemand), privacy: .public) to \(String(describing: demand), privacy: .public)"
            )
        }
    }

    func refresh() {
        guard !hasShutDown else { return }
        purgeExpiredSuspensions()
        monitoringCoordinator.requestEventRefresh(
            includesEssentialSystemProcesses: preferences.includesEssentialSystemProcesses
        )
    }

    private func handleMonitoringSample(_ sample: MonitoringSample) {
        guard !hasShutDown else { return }
        let demand = monitoringDemand

        if let systemCPU = sample.systemCPU {
            self.systemCPU = systemCPU
        }
        runtimeMetrics.setPowerSupported(sample.powerMetricsSupported)

        if let sampledApps = sample.apps {
            apps = sampledApps
            if demand.samplesApplications, sample.didRefreshApplications {
                runtimeMetrics.updateCPUAverages(apps: apps)
            }
            refreshRuleMetadata()
            if demand.samplesApplications, sample.didRefreshApplications {
                updateHighCPUState()
            }
            applyRulesToCurrentApps()
        }

        if demand.samplesPower, sample.apps != nil {
            updatePowerMetrics(powerByIdentifier: sample.powerByIdentifier)
        } else if !demand.samplesPower, !runtimeMetrics.savedPowerByIdentifier.isEmpty {
            runtimeMetrics.clearPowerMetrics()
            rebuildDisplayItems()
        }

        if demand.samplesApplications, sample.apps != nil {
            recordCPUHistorySample()
        }
    }

    func shutdown() async {
        guard !hasShutDown else { return }
        hasShutDown = true
        managementLedger.shutdown()

        workspaceEventMonitor.stop()
        historyStore.persistCPUHistory()
        runtimeMetrics.clearPowerMetrics()
        await monitoringCoordinator.shutdown()
        await managementCoordinator.shutdown()
    }

    private func applyRulesToCurrentApps() {
        managementCoordinator.update(
            apps: apps,
            rules: rules,
            suspensions: suspensions,
            activeProfile: preferences.activeProfile,
            isEnabled: isEnabled
        ) { [weak self] processChange in
            guard let self, !hasShutDown else { return }
            purgeExpiredSuspensions()
            monitoringCoordinator.requestEventRefresh(
                includesEssentialSystemProcesses: preferences.includesEssentialSystemProcesses,
                processChange: processChange
            )
        }
        apps = apps.map { app in
            var updated = app
            updated.status = managementCoordinator.statuses[app.bundleIdentifier] ?? .normal
            return updated
        }
        rebuildDisplayItems()
    }

    private func updatePowerMetrics(
        powerByIdentifier: [String: ProcessPowerSample]
    ) {
        apps = runtimeMetrics.updatePower(
            apps: apps,
            samples: powerByIdentifier,
            statuses: managementCoordinator.statuses,
            savedCPUByIdentifier: managementCoordinator.estimatedSavedCPUByIdentifier
        )
        rebuildDisplayItems()
    }

    private func updateHighCPUState() {
        let result = highCPUDetector.evaluate(
            apps: apps,
            preferences: preferences,
            suspendedIdentifiers: Set(suspensions.compactMap {
                $0.value.isActive ? $0.key : nil
            }),
            pendingAlert: pendingHighCPUAlert
        )
        attentionIdentifiers = result.attentionIdentifiers
        pendingHighCPUAlert = result.pendingAlert
        for event in result.events {
            recordActivity(
                bundleIdentifier: event.bundleIdentifier,
                kind: .highCPU,
                detail: String(format: "%.1f%% CPU", event.cpuPercent)
            )
        }
    }

    private func refreshRuleMetadata() {
        var changed = false
        for app in apps where !app.isSystemProcess {
            guard var rule = rules[app.bundleIdentifier] else { continue }
            if rule.displayName != app.name || rule.applicationURL != app.bundleURL {
                rule.displayName = app.name
                rule.applicationURL = app.bundleURL
                rules[app.bundleIdentifier] = rule
                changed = true
            }
        }
        if changed {
            persistRules()
        }
    }

    private func purgeExpiredSuspensions() {
        let expired = suspensions.values.filter { !$0.isActive }.map(\.bundleIdentifier)
        guard !expired.isEmpty else { return }
        expired.forEach { suspensions.removeValue(forKey: $0) }
        persistSuspensions()
    }

    private func handleControllerEvent(_ event: ProcessControllerEvent) {
        switch event {
        case .statusTransition(let identifier, let previous, let current):
            apps = apps.map { app in
                guard app.bundleIdentifier == identifier else { return app }
                var updated = app
                updated.status = current
                return updated
            }
            let displayName = apps.first { $0.bundleIdentifier == identifier }?.name
                ?? rules[identifier]?.displayName
                ?? identifier
            let applicationURL = apps.first { $0.bundleIdentifier == identifier }?.bundleURL
                ?? rules[identifier]?.applicationURL
            managementLedger.transition(
                bundleIdentifier: identifier,
                displayName: displayName,
                applicationURL: applicationURL,
                status: current
            )
            recordControllerTransition(
                bundleIdentifier: identifier,
                previous: previous,
                current: current
            )
            rebuildDisplayItems()
        case .activity(let identifier, let kind, let detail):
            recordActivity(bundleIdentifier: identifier, kind: kind, detail: detail)
        case .pauseWakeMonitoringChanged:
            break
        }
    }

    private func applyManagementState(
        statuses: [String: ManagementStatus],
        savedCPU: [String: Double]
    ) {
        apps = apps.map { app in
            var updated = app
            updated.status = statuses[app.bundleIdentifier] ?? .normal
            return updated
        }
        rebuildDisplayItems()
    }

    private func recordControllerTransition(
        bundleIdentifier: String,
        previous: ManagementStatus,
        current: ManagementStatus
    ) {
        let kind: ActivityKind
        let detail: String

        switch current {
        case .normal:
            guard previous != .normal else { return }
            kind = .restored
            detail = "Process returned to normal."
        case .waiting:
            kind = .waiting
            detail = "Waiting for the rule delay."
        case .limited(let percent):
            kind = .limited
            let cores = rules[bundleIdentifier]?.runOnEfficiencyCores == true
                ? " and using power-saving core scheduling"
                : ""
            detail = "Limited to \(Int(percent))% CPU\(cores)."
        case .paused:
            kind = .paused
            detail = "Paused while in the background."
        case .energyEfficient:
            kind = .energyEfficient
            detail = "Using power-saving core scheduling."
        case .audioProtected:
            kind = .audioProtected
            detail = "Rule held while audio is active."
        case .unavailable:
            kind = .error
            detail = "Tempra could not manage the process."
        case .snoozed, .disabled, .notRunning:
            return
        }

        recordActivity(bundleIdentifier: bundleIdentifier, kind: kind, detail: detail)
    }

    private func recordActivity(
        bundleIdentifier: String,
        kind: ActivityKind,
        detail: String
    ) {
        let displayName = apps.first { $0.bundleIdentifier == bundleIdentifier }?.name
            ?? rules[bundleIdentifier]?.displayName
            ?? bundleIdentifier
        activityEvents = historyStore.recordActivity(ActivityEvent(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            kind: kind,
            detail: detail
        ))
    }

    private func recordCPUHistorySample() {
        if let samples = historyStore.recordCPUHistory(
            systemCPU: systemCPU,
            estimatedSavedSystemPercent: estimatedSavedSystemPercent,
            interventionCount: activeManagementCount
        ) {
            cpuHistorySamples = samples
        }
    }

    private func loadRules() {
        rules = persistence.loadRules()
        persistRules()
    }

    private func loadPreferences() {
        preferences = persistence.loadPreferences()
    }

    private func loadSuspensions() {
        suspensions = persistence.loadSuspensions()
    }

    private func persistRules() {
        persistence.saveRules(rules)
    }

    private func persistPreferences() {
        persistence.savePreferences(preferences)
    }

    private func persistSuspensions() {
        persistence.saveSuspensions(suspensions)
    }

}
