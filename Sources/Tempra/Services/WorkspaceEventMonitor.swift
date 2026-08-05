import AppKit

enum ManagementLifecycleSuspension: Hashable, Sendable {
    case systemSleep
    case inactiveUserSession
}

@MainActor
final class WorkspaceEventMonitor {
    private var observers: [NSObjectProtocol] = []
    private var runningApplicationsObservation: NSKeyValueObservation?

    func start(
        onApplicationActivated: @escaping @MainActor @Sendable (String) async -> Void,
        onWillSuspend: @escaping @MainActor @Sendable (
            ManagementLifecycleSuspension
        ) async -> Void,
        onDidResume: @escaping @MainActor @Sendable (
            ManagementLifecycleSuspension
        ) -> Void,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        guard runningApplicationsObservation == nil, observers.isEmpty else { return }
        let workspace = NSWorkspace.shared
        runningApplicationsObservation = workspace.observe(
            \.runningApplications,
            options: [.new]
        ) { _, _ in
            Task { @MainActor in onChange() }
        }

        observers.append(workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let bundleIdentifier = (
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            )?.bundleIdentifier
            Task { @MainActor in
                if let bundleIdentifier {
                    await onApplicationActivated(bundleIdentifier)
                }
                onChange()
            }
        })

        observers.append(workspace.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await onWillSuspend(.systemSleep)
            }
        })

        observers.append(workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onDidResume(.systemSleep)
                onChange()
            }
        })

        observers.append(workspace.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await onWillSuspend(.inactiveUserSession)
            }
        })

        observers.append(workspace.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onDidResume(.inactiveUserSession)
                onChange()
            }
        })

        for name in [
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ] {
            observers.append(workspace.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in onChange() }
            })
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        runningApplicationsObservation?.invalidate()
        runningApplicationsObservation = nil
    }
}
