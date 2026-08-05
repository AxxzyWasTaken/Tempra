import AppKit
import Foundation

@MainActor
final class ProcessManagementCoordinator {
    typealias EventHandler = @MainActor @Sendable (ProcessControllerEvent) -> Void
    typealias StateHandler = @MainActor @Sendable (
        [String: ManagementStatus], [String: Double]
    ) -> Void
    typealias ChangeHandler = @MainActor @Sendable (ProcessChangeNotification) -> Void

    private struct AudioProtectionCandidate: Equatable {
        let bundleIdentifier: String
        let applicationURL: URL?

        init(_ app: ManagedApp) {
            bundleIdentifier = app.bundleIdentifier
            applicationURL = app.bundleURL
        }
    }

    private struct ProcessSampleConfiguration: Equatable {
        let identity: ProcessIdentity
        let isMainProcess: Bool
        let isPlayingAudio: Bool
        let networkActivity: ProcessNetworkActivity
        let hasCPUMeasurement: Bool

        init(_ sample: ManagedProcessSample) {
            identity = sample.identity
            isMainProcess = sample.isMainProcess
            isPlayingAudio = sample.isPlayingAudio
            networkActivity = sample.networkActivity
            hasCPUMeasurement = sample.hasCPUMeasurement
        }
    }

    private struct TargetConfiguration: Equatable {
        let bundleIdentifier: String
        let processIdentities: Set<ProcessIdentity>
        let processSamples: [ProcessSampleConfiguration]
        let usesApplicationCommands: Bool
        let launchedAt: Date?
        let isFrontmost: Bool
        let isHidden: Bool
        let isPlayingAudio: Bool
        let windowVisibility: AppWindowVisibility
        let isProtectedByForegroundOverlay: Bool
        let isProtectedAudioInfrastructure: Bool

        init(_ target: ProcessControlTarget) {
            bundleIdentifier = target.bundleIdentifier
            processIdentities = target.processIdentities
            processSamples = target.processSamples.map(ProcessSampleConfiguration.init)
            usesApplicationCommands = target.usesApplicationCommands
            launchedAt = target.launchedAt
            isFrontmost = target.isFrontmost
            isHidden = target.isHidden
            isPlayingAudio = target.isPlayingAudio
            windowVisibility = target.windowVisibility
            isProtectedByForegroundOverlay = target.isProtectedByForegroundOverlay
            isProtectedAudioInfrastructure = target.isProtectedAudioInfrastructure
        }
    }

    private struct ControlConfiguration: Equatable {
        let targets: [TargetConfiguration]
        let rules: [String: AppRule]
        let isEnabled: Bool

        init(
            targets: [ProcessControlTarget],
            rules: [String: AppRule],
            isEnabled: Bool
        ) {
            self.targets = targets
                .map(TargetConfiguration.init)
                .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
            self.rules = rules
            self.isEnabled = isEnabled
        }
    }

    private let controller: ProcessController
    private let processWatcher: ManagedProcessWatcher
    private var revision: UInt64 = 0
    private var controlConfiguration: ControlConfiguration?
    private var acceptsControllerResults = true
    private var updateTask: Task<Void, Never>?
    private var audioProtectionCandidates: [AudioProtectionCandidate] = []
    private var cachedProtectedAudioIdentifiers: Set<String> = []
    private var pauseActivationEventMonitor: Any?
    private var eventHandler: EventHandler?
    private var stateHandler: StateHandler?

    private(set) var statuses: [String: ManagementStatus] = [:]
    private(set) var estimatedSavedCPUByIdentifier: [String: Double] = [:]
    private(set) var activeCPULimitSessionIdentifiers: Set<String> = []
    private(set) var protectionReasonsByIdentifier:
        [String: [ProcessIdentity: Set<ProcessProtectionReason>]] = [:]

    init(
        controller: ProcessController,
        processWatcher: ManagedProcessWatcher
    ) {
        self.controller = controller
        self.processWatcher = processWatcher
    }

    convenience init() {
        self.init(
            controller: ProcessController(),
            processWatcher: ManagedProcessWatcher()
        )
    }

    func start(
        eventHandler: @escaping EventHandler,
        stateHandler: @escaping StateHandler
    ) {
        self.eventHandler = eventHandler
        self.stateHandler = stateHandler
        Task { [weak self, controller] in
            await controller.setEventHandler { [weak self] event in
                self?.handle(event)
            }
        }
    }

    func update(
        apps: [ManagedApp],
        rules: [String: AppRule],
        suspensions: [String: RuleSuspension],
        activeProfile: ManagementProfile?,
        isEnabled: Bool,
        onProcessChange: @escaping ChangeHandler
    ) {
        guard acceptsControllerResults, revision < .max else { return }
        let protectedAudioIdentifiers = resolveProtectedAudioIdentifiers(for: apps)
        let effectiveRules = rules.compactMapValues { rule -> AppRule? in
            guard rule.isEnabled,
                  !protectedAudioIdentifiers.contains(rule.bundleIdentifier),
                  suspensions[rule.bundleIdentifier]?.isActive != true else {
                return nil
            }
            let normalized = SystemProcessRulePolicy.normalized(
                activeProfile?.applying(to: rule) ?? rule
            )
            return normalized.hasBehavior ? normalized : nil
        }
        let managedApps = apps.filter { effectiveRules[$0.bundleIdentifier] != nil }
        processWatcher.watch(
            processIdentities: Set(managedApps.flatMap(\.processIdentities)),
            audioProcessIdentifiers: Set(managedApps.lazy.filter {
                effectiveRules[$0.bundleIdentifier]?.protectAudio == true
            }.flatMap(\.processIdentifiers)),
            onChange: onProcessChange
        )

        let targets = apps.lazy.map {
            ProcessControlTarget(
                bundleIdentifier: $0.bundleIdentifier,
                processIdentities: Set($0.processIdentities),
                processSamples: $0.processSamples,
                usesApplicationCommands: !$0.requiresPrivilegedControl
                    && !BackgroundProcessPolicy.isBackgroundIdentifier($0.bundleIdentifier),
                launchedAt: $0.launchedAt,
                cpuPercent: $0.cpuPercent,
                isFrontmost: $0.isFrontmost,
                isHidden: $0.isHidden,
                isPlayingAudio: $0.isPlayingAudio,
                windowVisibility: $0.windowVisibility,
                isProtectedByForegroundOverlay: $0.isProtectedByForegroundOverlay,
                isProtectedAudioInfrastructure: protectedAudioIdentifiers.contains(
                    $0.bundleIdentifier
                )
            )
        }
        let targetSnapshot = Array(targets)
        let configuration = ControlConfiguration(
            targets: targetSnapshot,
            rules: effectiveRules,
            isEnabled: isEnabled
        )
        let requiresReconciliation = configuration != controlConfiguration
        if requiresReconciliation {
            revision += 1
            controlConfiguration = configuration
        }
        updateTask?.cancel()
        let requestRevision = revision
        updateTask = Task { [weak self, controller] in
            let snapshot = if requiresReconciliation {
                await controller.update(
                    targets: targetSnapshot,
                    rules: effectiveRules,
                    isEnabled: isEnabled,
                    revision: requestRevision
                )
            } else {
                await controller.updateMeasurements(targets: targetSnapshot)
            }
            guard !Task.isCancelled else { return }
            self?.apply(snapshot)
        }
    }

    private func resolveProtectedAudioIdentifiers(
        for apps: [ManagedApp]
    ) -> Set<String> {
        let candidates = apps
            .map(AudioProtectionCandidate.init)
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        guard candidates != audioProtectionCandidates else {
            return cachedProtectedAudioIdentifiers
        }

        audioProtectionCandidates = candidates
        cachedProtectedAudioIdentifiers = Set(candidates.compactMap { candidate in
            SoundSourceCompatibilityPolicy.isProtected(
                bundleIdentifier: candidate.bundleIdentifier,
                applicationURL: candidate.applicationURL
            ) ? candidate.bundleIdentifier : nil
        })
        return cachedProtectedAudioIdentifiers
    }

    func shutdown() async -> ProcessRestorationResult {
        acceptsControllerResults = false
        updateTask?.cancel()
        updateTask = nil
        if let pauseActivationEventMonitor {
            NSEvent.removeMonitor(pauseActivationEventMonitor)
            self.pauseActivationEventMonitor = nil
        }
        await processWatcher.stop()
        let result = await controller.shutdown()
        if result.succeeded {
            eventHandler = nil
            stateHandler = nil
        }
        return result
    }

    func performApplicationCommand(
        _ command: ApplicationCommand,
        bundleIdentifier: String
    ) async -> ApplicationCommandOutcome {
        await controller.performApplicationCommand(
            command,
            bundleIdentifier: bundleIdentifier
        )
    }

    func suspendForSystemTransition() async -> ProcessRestorationResult {
        guard acceptsControllerResults else { return .success }
        updateTask?.cancel()
        updateTask = nil
        let snapshot = await controller.suspendForSystemTransition()
        if snapshot.revision == revision {
            apply(snapshot)
        }
        return await controller.currentRestorationResult()
    }

    func resumeAfterSystemTransition() async {
        guard acceptsControllerResults else { return }
        let snapshot = await controller.resumeAfterSystemTransition()
        if snapshot.revision == revision {
            apply(snapshot)
        }
    }

    func recentSignalEvents() async -> [ProcessControlSignalEvent] {
        await controller.recentSignalEvents()
    }

    func recentLimitMeasurements() async -> [ProcessLimitMeasurement] {
        await controller.recentLimitMeasurements()
    }

    func applicationDidActivate(bundleIdentifier: String) async {
        guard acceptsControllerResults else { return }
        let requestRevision = revision
        let snapshot = await controller.applicationDidActivate(
            bundleIdentifier: bundleIdentifier
        )
        guard acceptsControllerResults, revision == requestRevision else { return }
        apply(snapshot)
    }

    private func handle(_ event: ProcessControllerEvent) {
        guard acceptsControllerResults else { return }
        switch event {
        case .statusTransition(
            let eventRevision,
            let identifier,
            _,
            let current,
            let isCPULimitSessionActive
        ):
            guard eventRevision == revision else { return }
            statuses[identifier] = current
            if isCPULimitSessionActive {
                activeCPULimitSessionIdentifiers.insert(identifier)
            } else {
                activeCPULimitSessionIdentifiers.remove(identifier)
            }
            eventHandler?(event)
            stateHandler?(statuses, estimatedSavedCPUByIdentifier)
        case .activity(let eventRevision, _, _, _):
            guard eventRevision == revision else { return }
            eventHandler?(event)
        case .pauseWakeMonitoringChanged(let eventRevision, let enabled):
            guard eventRevision == revision else { return }
            setPauseWakeMonitoringEnabled(enabled)
        }
    }

    private func apply(_ snapshot: ProcessControlSnapshot) {
        guard acceptsControllerResults, snapshot.revision == revision else { return }
        let publishesState = statuses != snapshot.statuses
            || estimatedSavedCPUByIdentifier != snapshot.estimatedSavedCPUByIdentifier
            || activeCPULimitSessionIdentifiers
                != snapshot.activeCPULimitSessionIdentifiers
            || protectionReasonsByIdentifier != snapshot.protectionReasonsByIdentifier
        statuses = snapshot.statuses
        estimatedSavedCPUByIdentifier = snapshot.estimatedSavedCPUByIdentifier
        activeCPULimitSessionIdentifiers = snapshot.activeCPULimitSessionIdentifiers
        protectionReasonsByIdentifier = snapshot.protectionReasonsByIdentifier
        if publishesState {
            stateHandler?(statuses, estimatedSavedCPUByIdentifier)
        }
    }

    private func setPauseWakeMonitoringEnabled(_ enabled: Bool) {
        if enabled, pauseActivationEventMonitor == nil {
            pauseActivationEventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [controller] _ in
                Task {
                    await controller.wakePausedApplicationsForUserActivation()
                }
            }
        } else if !enabled, let pauseActivationEventMonitor {
            NSEvent.removeMonitor(pauseActivationEventMonitor)
            self.pauseActivationEventMonitor = nil
        }
    }
}
