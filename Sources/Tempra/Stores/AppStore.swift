import AppKit
import Combine
import Foundation
import OSLog

private let monitoringLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "io.github.temperapp.Temper",
    category: "Monitoring"
)

struct ApplicationActionFailurePresentation: Equatable {
    let bundleIdentifier: String
    let message: String
}

@MainActor
final class AppStore: ObservableObject {
    typealias PersistenceErrorHandler = @MainActor @Sendable (Error) -> Void

    private(set) var apps: [ManagedApp] = []
    @Published private(set) var rules: [String: AppRule] = [:]
    @Published private(set) var preferences = AppPreferences()
    @Published private(set) var suspensions: [String: RuleSuspension] = [:]
    @Published private(set) var activityEvents: [ActivityEvent] = []
    @Published private(set) var cpuHistorySamples: [CPUHistorySample] = []
    @Published private(set) var systemCPU = SystemCPUSnapshot()
    @Published private(set) var attentionIdentifiers: Set<String> = []
    @Published private(set) var pendingHighCPUAlert: HighCPUAlert?
    @Published private(set) var applicationActionFailure: ApplicationActionFailurePresentation?
    @Published private(set) var isEnabled: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var privilegedControlStatus: PrivilegedControlStatus
    @Published var displayItems: [AppDisplayItem] = []

    let managementCoordinator: ProcessManagementCoordinator
    private let launchAtLoginController: any LaunchAtLoginControlling
    private let privilegedHelperManager: PrivilegedHelperManager
    private let persistence: AppPersistence
    private let monitoringService: any MonitoringServicing
    private let persistenceErrorHandler: PersistenceErrorHandler
    private let historyStore: AppHistoryStore
    private let suspensionClock: SuspensionExpirationClock
    let iconCache: AppIconCache
    let managementLedger: ManagementLedger
    private lazy var monitoringCoordinator = MonitoringCoordinator(
        service: monitoringService
    ) { [weak self] sample in self?.handleMonitoringSample(sample) }
    private let workspaceEventMonitor = WorkspaceEventMonitor()
    private var highCPUDetector = HighCPUDetector()
    var runtimeMetrics = RuntimeMetrics()
    private var isPresentationActive = false
    private var hasBegunShutdown = false
    private var hasShutDown = false
    private var persistedEnabled: Bool
    private var persistedRules: [String: AppRule]
    private var persistedPreferences: AppPreferences
    private var persistedSuspensions: [String: RuleSuspension]
    private var suspensionExpirationTask: Task<Void, Never>?
    private var suspensionExpirationID: UUID?

    convenience init(
        persistenceErrorHandler: @escaping PersistenceErrorHandler
    ) throws {
        try self.init(
            persistence: AppPersistence(),
            managementCoordinator: ProcessManagementCoordinator(),
            monitoringService: MonitoringService(),
            launchAtLoginController: LaunchAtLoginController(),
            startsMonitoring: true,
            persistenceErrorHandler: persistenceErrorHandler
        )
    }

    init(
        persistence: AppPersistence,
        managementCoordinator: ProcessManagementCoordinator,
        monitoringService: any MonitoringServicing,
        launchAtLoginController: any LaunchAtLoginControlling,
        startsMonitoring: Bool,
        iconCache: AppIconCache? = nil,
        privilegedHelperManager: PrivilegedHelperManager? = nil,
        suspensionClock: SuspensionExpirationClock = .continuous,
        persistenceErrorHandler: @escaping PersistenceErrorHandler
    ) throws {
        let loadedEnabled = try persistence.loadEnabled()
        let loadedRules = try persistence.loadRules()
        let safeLoadedRules = loadedRules.compactMapValues { rule -> AppRule? in
            let normalized = SystemProcessRulePolicy.normalized(rule)
            return normalized.hasBehavior ? normalized : nil
        }
        if safeLoadedRules != loadedRules {
            try persistence.saveRules(safeLoadedRules)
        }
        var loadedPreferences = try persistence.loadPreferences()
        let loadedSuspensions = try persistence.loadSuspensions()
        let loadedActivity = try persistence.loadActivity()
        let loadedCPUHistory = try persistence.loadCPUHistory()
        let historyStore = AppHistoryStore(
            persistence: persistence,
            activityEvents: loadedActivity,
            cpuHistorySamples: loadedCPUHistory
        )
        let managementLedger = try ManagementLedger(
            defaults: persistence.defaults,
            activityEvents: historyStore.activityEvents
        )
        try managementLedger.persistLoadedState()

        self.persistence = persistence
        self.managementCoordinator = managementCoordinator
        self.monitoringService = monitoringService
        self.launchAtLoginController = launchAtLoginController
        let privilegedHelperManager = privilegedHelperManager ?? PrivilegedHelperManager()
        self.privilegedHelperManager = privilegedHelperManager
        self.persistenceErrorHandler = persistenceErrorHandler
        self.historyStore = historyStore
        self.suspensionClock = suspensionClock
        self.iconCache = iconCache ?? AppIconCache()
        self.managementLedger = managementLedger
        isEnabled = loadedEnabled
        privilegedControlStatus = privilegedHelperManager.status
        rules = safeLoadedRules
        loadedPreferences.launchAtLogin = launchAtLoginController.isEnabled
        preferences = loadedPreferences
        suspensions = loadedSuspensions
        activityEvents = historyStore.activityEvents
        cpuHistorySamples = historyStore.cpuHistorySamples
        persistedEnabled = loadedEnabled
        persistedRules = safeLoadedRules
        persistedPreferences = loadedPreferences
        persistedSuspensions = loadedSuspensions
        managementLedger.startHeartbeat { [weak self] error in
            self?.reportPersistenceError(error)
        }

        if launchAtLoginController.requiresApproval {
            launchAtLoginError = "Approve Tempra in System Settings › General › Login Items."
        }
        managementCoordinator.start(
            eventHandler: { [weak self] event in
                self?.handleControllerEvent(event)
            },
            stateHandler: { [weak self] statuses, savedCPU in
                self?.applyManagementState(statuses: statuses, savedCPU: savedCPU)
            }
        )
        scheduleSuspensionExpiration()

        if startsMonitoring {
            workspaceEventMonitor.start(
                onApplicationActivated: { [weak self] bundleIdentifier in
                    await self?.managementCoordinator.applicationDidActivate(
                        bundleIdentifier: bundleIdentifier
                    )
                },
                onChange: { [weak self] in
                    self?.refresh()
                }
            )
            configureMonitoringDemand(refreshImmediately: false)
            refresh()
        }
    }

    func save(_ rule: AppRule) {
        var normalized = rule
        normalized.limitPercent = CPULimitRange.clamped(normalized.limitPercent)
        if normalized.action == .limit || normalized.action == .pause {
            normalized.runOnEfficiencyCores = false
        }
        if normalized.applicationURL == nil {
            normalized.applicationURL = apps.first {
                $0.bundleIdentifier == normalized.bundleIdentifier
            }?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalized.bundleIdentifier)
        }
        normalized = SystemProcessRulePolicy.normalized(normalized)
        normalized.updatedAt = Date()

        if !normalized.hasBehavior {
            removeRule(bundleIdentifier: normalized.bundleIdentifier)
            return
        }

        rules[normalized.bundleIdentifier] = normalized
        guard persistRules() else { return }
        recordActivity(
            bundleIdentifier: normalized.bundleIdentifier,
            kind: normalized.isEnabled ? .ruleSaved : .ruleDisabled,
            detail: normalized.summary
        )
        applyRulesToCurrentApps()
        configureMonitoringDemand(refreshImmediately: true)
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
        if action == .limit || action == .pause {
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
        let previousRules = rules
        let previousSuspensions = suspensions
        rules.removeValue(forKey: bundleIdentifier)
        suspensions.removeValue(forKey: bundleIdentifier)
        guard persistRulesAndSuspensions(
            previousRules: previousRules,
            previousSuspensions: previousSuspensions
        ) else { return }
        scheduleSuspensionExpiration()
        recordActivity(
            bundleIdentifier: bundleIdentifier,
            kind: .ruleRemoved,
            detail: "Tempra will no longer manage this app."
        )
        applyRulesToCurrentApps()
        configureMonitoringDemand(refreshImmediately: true)
    }

    func snooze(bundleIdentifier: String, for duration: TimeInterval) {
        let until = suspensionClock.now().addingTimeInterval(duration)
        suspensions[bundleIdentifier] = RuleSuspension(
            bundleIdentifier: bundleIdentifier,
            until: until
        )
        guard persistSuspensions() else { return }
        recordActivity(
            bundleIdentifier: bundleIdentifier,
            kind: .snoozed,
            detail: "Until \(until.formatted(date: .omitted, time: .shortened))"
        )
        scheduleSuspensionExpiration()
        applyRulesToCurrentApps()
    }

    func endSnooze(bundleIdentifier: String) {
        guard suspensions.removeValue(forKey: bundleIdentifier) != nil else { return }
        guard persistSuspensions() else { return }
        scheduleSuspensionExpiration()
        applyRulesToCurrentApps()
    }

    func performApplicationCommand(
        _ command: ApplicationCommand,
        for item: AppDisplayItem
    ) async -> Bool {
        guard !hasBegunShutdown else { return false }
        guard item.canManageProcess else {
            setApplicationActionFailure(
                for: item,
                message: "Tempra keeps this SoundSource audio component running so audio "
                    + "routing and effects continue to work."
            )
            return false
        }
        guard item.isRunning else {
            setApplicationActionFailure(
                for: item,
                message: "\(item.name) is no longer running."
            )
            return false
        }
        if item.requiresPrivilegedControl, !privilegedControlStatus.isEnabled {
            let status = await requestPrivilegedControl()
            setApplicationActionFailure(
                for: item,
                message: status.message
                    ?? "Tempra is waiting for a verified process identity."
            )
            return false
        }
        if item.requiresPrivilegedControl, item.controllableProcessCount == 0 {
            setApplicationActionFailure(
                for: item,
                message: "Tempra does not yet have a verified identity for \(item.name)."
            )
            refresh()
            return false
        }

        applicationActionFailure = nil
        let outcome = await managementCoordinator.performApplicationCommand(
            command,
            bundleIdentifier: item.bundleIdentifier
        )
        switch outcome {
        case .succeeded:
            return true
        case .failed(let failure):
            setApplicationActionFailure(
                for: item,
                message: applicationCommandFailureMessage(
                    command: command,
                    failure: failure,
                    appName: item.name
                )
            )
            return false
        }
    }

    func revealApplication(_ item: AppDisplayItem) -> Bool {
        guard let applicationURL = item.applicationURL,
              applicationURL.isFileURL,
              FileManager.default.fileExists(atPath: applicationURL.path) else {
            setApplicationActionFailure(
                for: item,
                message: "Tempra could not find \(item.name) in Finder."
            )
            return false
        }
        applicationActionFailure = nil
        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
        return true
    }

    func applicationActionFailureMessage(for bundleIdentifier: String) -> String? {
        guard applicationActionFailure?.bundleIdentifier == bundleIdentifier else {
            return nil
        }
        return applicationActionFailure?.message
    }

    func dismissApplicationActionFailure() {
        applicationActionFailure = nil
    }

    func requestPrivilegedControl() async -> PrivilegedControlStatus {
        let status = await privilegedHelperManager.requestEnable()
        privilegedControlStatus = status
        if status.isEnabled {
            refresh()
        }
        return status
    }

    func openPrivilegedControlSettings() {
        privilegedHelperManager.openApprovalSettings()
    }

    func setEnabled(_ enabled: Bool) {
        guard !hasBegunShutdown else { return }
        isEnabled = enabled
        do {
            try persistence.saveEnabled(enabled)
            persistedEnabled = enabled
        } catch {
            isEnabled = persistedEnabled
            reportPersistenceError(error)
            return
        }
        applyRulesToCurrentApps()
    }

    func setHighCPUAlertsEnabled(_ enabled: Bool) {
        preferences.highCPUAlertsEnabled = enabled
        guard persistPreferences() else { return }
        if !enabled {
            pendingHighCPUAlert = nil
        }
    }

    func setHighCPUThreshold(_ threshold: Double) {
        preferences.highCPUThreshold = min(
            max(25, threshold),
            CPULimitRange.maximumPercent
        )
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
        guard persistPreferences() else { return }
        if pendingHighCPUAlert?.bundleIdentifier == bundleIdentifier {
            pendingHighCPUAlert = nil
        }
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
        guard persistPreferences() else { return nil }
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
        preferences.profiles[index].limitPercent = CPULimitRange.clamped(
            preferences.profiles[index].limitPercent
        )
        preferences.profiles[index].delaySeconds = min(
            max(0, preferences.profiles[index].delaySeconds),
            5 * 60
        )
        guard persistPreferences() else { return }
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
        guard persistPreferences() else { return }
        applyRulesToCurrentApps()
    }

    func setActiveManagementProfile(_ id: UUID?) {
        guard id == nil || preferences.profiles.contains(where: { $0.id == id }) else {
            return
        }
        preferences.activeProfileID = id
        guard persistPreferences() else { return }
        applyRulesToCurrentApps()
    }

    func setAppearance(_ appearance: AppAppearance) {
        preferences.appearance = appearance
        persistPreferences()
    }

    func setIncludesEssentialSystemProcesses(_ includes: Bool) {
        guard preferences.includesEssentialSystemProcesses != includes else { return }
        preferences.includesEssentialSystemProcesses = includes
        guard persistPreferences() else { return }
        configureMonitoringDemand(refreshImmediately: true)
    }

    func setContinuousMonitoringEnabled(_ enabled: Bool) {
        guard preferences.continuousMonitoringEnabled != enabled else { return }
        preferences.continuousMonitoringEnabled = enabled
        guard persistPreferences() else { return }
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
        guard persistPreferences() else { return }
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
        persistedPreferences.launchAtLogin = preferences.launchAtLogin
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
            do {
                try historyStore.persistCPUHistory()
            } catch {
                reportPersistenceError(error)
            }
        }
        monitoringCoordinator.configure(
            demand: demand,
            refreshImmediately: refreshImmediately,
            includesEssentialSystemProcesses: includesBackgroundAndSystemProcesses
        )

        if previousDemand != demand {
            monitoringLogger.debug(
                "Monitoring mode changed from \(String(describing: previousDemand), privacy: .public) to \(String(describing: demand), privacy: .public)"
            )
        }
    }

    func refresh() {
        guard !hasBegunShutdown else { return }
        if purgeExpiredSuspensions() {
            scheduleSuspensionExpiration()
        }
        monitoringCoordinator.requestEventRefresh(
            includesEssentialSystemProcesses: includesBackgroundAndSystemProcesses
        )
    }

    private func handleMonitoringSample(_ sample: MonitoringSample) {
        applyMonitoringSample(sample, demand: monitoringDemand)
    }

    func applyMonitoringSample(
        _ sample: MonitoringSample,
        demand: MonitoringDemand
    ) {
        guard !hasBegunShutdown else { return }
        var rebuildsDisplayItems = false

        let activeLimitIdentifiers = Set(
            managementCoordinator.statuses.compactMap { identifier, status in
                status.isActivelyLimitingCPU ? identifier : nil
            }
        )
        runtimeMetrics.updateBatteryPower(
            state: sample.batteryPower,
            activeLimitIdentifiers: activeLimitIdentifiers
        )

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
            applyRulesToCurrentApps(rebuildsDisplayItems: false)
            rebuildsDisplayItems = true
        }

        if let privilegedAccessError = sample.privilegedAccessError,
           privilegedHelperManager.status == .enabled {
            privilegedControlStatus = .helperUnavailable(privilegedAccessError)
        } else {
            privilegedControlStatus = privilegedHelperManager.status
        }

        if demand.samplesPower, sample.apps != nil {
            updatePowerMetrics(powerByIdentifier: sample.powerByIdentifier)
            rebuildsDisplayItems = true
        } else if !demand.samplesPower, !runtimeMetrics.savedPowerByIdentifier.isEmpty {
            runtimeMetrics.clearPowerMetrics()
            rebuildsDisplayItems = true
        }

        if rebuildsDisplayItems {
            rebuildDisplayItems()
        }

        if sample.systemCPU != nil {
            recordCPUHistorySample(
                includesApplicationMetrics: demand.samplesApplications && sample.apps != nil
            )
        }
    }

    func shutdown() async -> ProcessRestorationResult {
        guard !hasShutDown else { return .success }
        if !hasBegunShutdown {
            hasBegunShutdown = true
            suspensionExpirationTask?.cancel()
            suspensionExpirationTask = nil
            suspensionExpirationID = nil
            isEnabled = false
            do {
                try managementLedger.shutdown()
            } catch {
                reportPersistenceError(error)
            }
            do {
                try historyStore.persistCPUHistory()
            } catch {
                reportPersistenceError(error)
            }
            workspaceEventMonitor.stop()
            runtimeMetrics.clearPowerMetrics()
            await monitoringCoordinator.shutdown()
        }
        let result = await managementCoordinator.shutdown()
        hasShutDown = result.succeeded
        return result
    }

    private func applyRulesToCurrentApps(rebuildsDisplayItems: Bool = true) {
        guard !hasBegunShutdown else { return }
        managementCoordinator.update(
            apps: apps,
            rules: rules,
            suspensions: suspensions,
            activeProfile: preferences.activeProfile,
            isEnabled: isEnabled
        ) { [weak self] processChange in
            guard let self, !hasBegunShutdown else { return }
            if purgeExpiredSuspensions() {
                scheduleSuspensionExpiration()
            }
            monitoringCoordinator.requestEventRefresh(
                includesEssentialSystemProcesses: includesBackgroundAndSystemProcesses,
                processChange: processChange
            )
        }
        apps = apps.map { app in
            var updated = app
            updated.status = managementCoordinator.statuses[app.bundleIdentifier] ?? .normal
            return updated
        }
        if rebuildsDisplayItems {
            rebuildDisplayItems()
        }
    }

    private var includesBackgroundAndSystemProcesses: Bool {
        preferences.includesEssentialSystemProcesses
            || rules.keys.contains(where: BackgroundProcessPolicy.isMonitorOnlyIdentifier)
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
        for app in apps {
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

    @discardableResult
    private func purgeExpiredSuspensions() -> Bool {
        let now = suspensionClock.now()
        let expired = suspensions.values.filter { $0.until <= now }.map(\.bundleIdentifier)
        guard !expired.isEmpty else { return false }
        expired.forEach { suspensions.removeValue(forKey: $0) }
        persistSuspensions()
        return true
    }

    private func scheduleSuspensionExpiration() {
        suspensionExpirationTask?.cancel()
        suspensionExpirationTask = nil
        suspensionExpirationID = nil

        let now = suspensionClock.now()
        guard !hasBegunShutdown,
              let deadline = suspensions.values.lazy.map(\.until).filter({ $0 > now }).min() else {
            return
        }

        let expirationID = UUID()
        suspensionExpirationID = expirationID
        suspensionExpirationTask = Task { @MainActor [weak self, suspensionClock] in
            let reachedDeadline = await suspensionClock.sleepUntil(deadline)
            guard reachedDeadline, !Task.isCancelled else { return }
            self?.handleSuspensionExpiration(id: expirationID)
        }
    }

    private func handleSuspensionExpiration(id: UUID) {
        guard suspensionExpirationID == id, !hasBegunShutdown else { return }
        suspensionExpirationTask = nil
        suspensionExpirationID = nil
        let didExpire = purgeExpiredSuspensions()
        if didExpire {
            applyRulesToCurrentApps()
        }
        scheduleSuspensionExpiration()
    }

    private func handleControllerEvent(_ event: ProcessControllerEvent) {
        switch event {
        case .statusTransition(_, let identifier, let previous, let current):
            let displayName = apps.first { $0.bundleIdentifier == identifier }?.name
                ?? rules[identifier]?.displayName
                ?? identifier
            let applicationURL = apps.first { $0.bundleIdentifier == identifier }?.bundleURL
                ?? rules[identifier]?.applicationURL
            let isInternalLimitPhaseChange = ManagementMetricCategory(status: previous) == .limited
                && ManagementMetricCategory(status: current) == .limited
            if !isInternalLimitPhaseChange {
                do {
                    try managementLedger.transition(
                        bundleIdentifier: identifier,
                        displayName: displayName,
                        applicationURL: applicationURL,
                        status: current
                    )
                } catch {
                    reportPersistenceError(error)
                }
                recordControllerTransition(
                    bundleIdentifier: identifier,
                    previous: previous,
                    current: current
                )
            }
        case .activity(_, let identifier, let kind, let detail):
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
            let cores = rules[bundleIdentifier]?.usesEfficiencyCoreScheduling == true
                ? " and using power-saving core scheduling"
                : ""
            detail = "Limited to \(Int(percent))% CPU\(cores)."
        case .limitedWithProtectedProcesses:
            kind = .limited
            detail = "Limiting CPU-heavy processes while essential helpers remain active."
        case .paused:
            kind = .paused
            detail = "Paused while in the background."
        case .energyEfficient:
            kind = .energyEfficient
            detail = "Using power-saving core scheduling."
        case .audioProtected:
            kind = .audioProtected
            detail = "Rule held while audio is active."
        case .networkProtected:
            kind = .networkProtected
            detail = "Rule held while this process has an active network connection."
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
        do {
            activityEvents = try historyStore.recordActivity(ActivityEvent(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                kind: kind,
                detail: detail
            ))
        } catch {
            reportPersistenceError(error)
        }
    }

    private func recordCPUHistorySample(includesApplicationMetrics: Bool) {
        do {
            if let samples = try historyStore.recordCPUHistory(
                systemCPU: systemCPU,
                estimatedSavedSystemPercent: includesApplicationMetrics
                    ? estimatedSavedSystemPercent
                    : nil,
                interventionCount: activeManagementCount
            ) {
                cpuHistorySamples = samples
            }
        } catch {
            reportPersistenceError(error)
        }
    }

    @discardableResult
    private func persistRules() -> Bool {
        do {
            try persistence.saveRules(rules)
            persistedRules = rules
            return true
        } catch {
            rules = persistedRules
            reportPersistenceError(error)
            return false
        }
    }

    @discardableResult
    private func persistPreferences() -> Bool {
        do {
            try persistence.savePreferences(preferences)
            persistedPreferences = preferences
            return true
        } catch {
            preferences = persistedPreferences
            reportPersistenceError(error)
            return false
        }
    }

    @discardableResult
    private func persistSuspensions() -> Bool {
        do {
            try persistence.saveSuspensions(suspensions)
            persistedSuspensions = suspensions
            return true
        } catch {
            suspensions = persistedSuspensions
            reportPersistenceError(error)
            return false
        }
    }

    private func persistRulesAndSuspensions(
        previousRules: [String: AppRule],
        previousSuspensions: [String: RuleSuspension]
    ) -> Bool {
        do {
            try persistence.saveRules(rules)
            try persistence.saveSuspensions(suspensions)
            persistedRules = rules
            persistedSuspensions = suspensions
            return true
        } catch let saveError {
            rules = previousRules
            suspensions = previousSuspensions
            do {
                try persistence.saveRules(previousRules)
                try persistence.saveSuspensions(previousSuspensions)
                persistedRules = previousRules
                persistedSuspensions = previousSuspensions
            } catch let rollbackError {
                reportPersistenceError(rollbackError)
            }
            reportPersistenceError(saveError)
            return false
        }
    }

    private func setApplicationActionFailure(for item: AppDisplayItem, message: String) {
        applicationActionFailure = ApplicationActionFailurePresentation(
            bundleIdentifier: item.bundleIdentifier,
            message: message
        )
    }

    private func applicationCommandFailureMessage(
        command: ApplicationCommand,
        failure: ApplicationCommandFailure,
        appName: String
    ) -> String {
        switch failure {
        case .notRunning:
            return "\(appName) is no longer running."
        case .compatibilityProtected:
            return "Tempra keeps this SoundSource audio component running so audio "
                + "routing and effects continue to work."
        case .restorationFailed:
            return "Tempra could not safely resume every process for \(appName), "
                + "so it did not send the command. Try again."
        case .requestRejected:
            let commandName = switch command {
            case .bringToFront: "bring \(appName) to the front"
            case .hide: "hide \(appName)"
            case .quit: "force quit \(appName)"
            }
            return "macOS did not accept the request to \(commandName)."
        }
    }

    private func reportPersistenceError(_ error: Error) {
        persistenceErrorHandler(error)
    }

}
