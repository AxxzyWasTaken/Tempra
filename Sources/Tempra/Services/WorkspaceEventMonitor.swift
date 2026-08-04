import AppKit

@MainActor
final class WorkspaceEventMonitor {
    private var observers: [NSObjectProtocol] = []
    private var runningApplicationsObservation: NSKeyValueObservation?

    func start(
        onApplicationActivated: @escaping @MainActor @Sendable (String) async -> Void,
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

        for name in [
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didWakeNotification
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
