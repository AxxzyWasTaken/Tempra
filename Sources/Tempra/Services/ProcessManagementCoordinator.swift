import AppKit
import Foundation

@MainActor
final class ProcessManagementCoordinator {
    typealias EventHandler = @MainActor @Sendable (ProcessControllerEvent) -> Void
    typealias StateHandler = @MainActor @Sendable (
        [String: ManagementStatus], [String: Double]
    ) -> Void
    typealias ChangeHandler = @MainActor @Sendable (ProcessChangeNotification) -> Void

    private let controller: ProcessController
    private let processWatcher: ManagedProcessWatcher
    private var revision: UInt64 = 0
    private var updateTask: Task<Void, Never>?
    private var pauseActivationEventMonitor: Any?
    private var eventHandler: EventHandler?
    private var stateHandler: StateHandler?

    private(set) var statuses: [String: ManagementStatus] = [:]
    private(set) var estimatedSavedCPUByIdentifier: [String: Double] = [:]

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
        let monitorOnlyIdentifiers = Set(
            apps.lazy.filter(\.isSystemProcess).map(\.bundleIdentifier)
        )
        let effectiveRules = rules.compactMapValues { rule -> AppRule? in
            guard rule.hasBehavior,
                  rule.isEnabled,
                  !BackgroundProcessPolicy.isMonitorOnlyIdentifier(rule.bundleIdentifier),
                  !monitorOnlyIdentifiers.contains(rule.bundleIdentifier),
                  suspensions[rule.bundleIdentifier]?.isActive != true else {
                return nil
            }
            return activeProfile?.applying(to: rule) ?? rule
        }
        let managedApps = apps.filter {
            !$0.isSystemProcess && effectiveRules[$0.bundleIdentifier] != nil
        }
        processWatcher.watch(
            processIdentities: Set(managedApps.flatMap(\.processIdentities)),
            audioProcessIdentifiers: Set(managedApps.lazy.filter {
                effectiveRules[$0.bundleIdentifier]?.protectAudio == true
            }.flatMap(\.processIdentifiers)),
            onChange: onProcessChange
        )

        revision &+= 1
        let requestRevision = revision
        let targets = apps.lazy.filter { !$0.isSystemProcess }.map {
            ProcessControlTarget(
                bundleIdentifier: $0.bundleIdentifier,
                processIdentities: Set($0.processIdentities),
                launchedAt: $0.launchedAt,
                cpuPercent: $0.cpuPercent,
                isFrontmost: $0.isFrontmost,
                isHidden: $0.isHidden,
                isPlayingAudio: $0.isPlayingAudio,
                windowVisibility: $0.windowVisibility,
                isProtectedByMenuBarOverlay: $0.isProtectedByMenuBarOverlay
            )
        }
        let targetSnapshot = Array(targets)
        updateTask?.cancel()
        updateTask = Task { [weak self, controller] in
            let snapshot = await controller.update(
                targets: targetSnapshot,
                rules: effectiveRules,
                isEnabled: isEnabled,
                revision: requestRevision
            )
            guard !Task.isCancelled else { return }
            self?.apply(snapshot)
        }
    }

    func shutdown() async -> ProcessRestorationResult {
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

    private func handle(_ event: ProcessControllerEvent) {
        switch event {
        case .statusTransition(let identifier, _, let current):
            statuses[identifier] = current
            stateHandler?(statuses, estimatedSavedCPUByIdentifier)
            eventHandler?(event)
        case .activity:
            eventHandler?(event)
        case .pauseWakeMonitoringChanged(let enabled):
            setPauseWakeMonitoringEnabled(enabled)
        }
    }

    private func apply(_ snapshot: ProcessControlSnapshot) {
        guard snapshot.revision == revision else { return }
        statuses = snapshot.statuses
        estimatedSavedCPUByIdentifier = snapshot.estimatedSavedCPUByIdentifier
        stateHandler?(statuses, estimatedSavedCPUByIdentifier)
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
