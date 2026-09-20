import AppKit

@main
@MainActor
enum TempraApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        _ = delegate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuPanelCoordinator: MenuPanelCoordinator?
    private var store: AppStore?
    private let terminationCoordinator = ApplicationTerminationCoordinator()
    private let updateController = TempraUpdateController()
    private let guardianLeaseHeartbeat = ProcessGuardianLeaseHeartbeat()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try AppStore { error in
                Self.presentPersistenceFailure(error)
            }
            self.store = store
            let menuPanelCoordinator = MenuPanelCoordinator(
                store: store,
                updateController: updateController
            )
            self.menuPanelCoordinator = menuPanelCoordinator
            guardianLeaseHeartbeat.start()
            menuPanelCoordinator.presentPrivilegedAccessOnboardingIfNeeded()
        } catch {
            Self.presentStartupFailure(error)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        menuPanelCoordinator?.closePanels()
        terminationCoordinator.begin(
            shutdown: {
                await store.shutdown()
            },
            presentFailure: { result in
                Self.presentRestorationFailure(
                    result,
                    displayName: { store.displayName(forBundleIdentifier: $0) }
                )
            },
            invalidate: { [weak self] in
                self?.guardianLeaseHeartbeat.stop()
                self?.menuPanelCoordinator?.invalidate()
                self?.menuPanelCoordinator = nil
            },
            reply: { shouldTerminate in
                sender.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        )
        return .terminateLater
    }

    private static func presentStartupFailure(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Tempra could not load its saved data"
        alert.informativeText = error.localizedDescription
            + " Tempra did not overwrite the saved data and will now quit."
        alert.addButton(withTitle: "Quit Tempra")
        alert.runModal()
    }

    private static func presentPersistenceFailure(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Tempra could not save this change"
        alert.informativeText = error.localizedDescription
            + " Tempra did not treat the failed write as successful."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func presentRestorationFailure(
        _ result: ProcessRestorationResult,
        displayName: (String) -> String
    ) -> TerminationFailureAction {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Tempra could not safely quit"
        alert.informativeText = restorationFailureText(result, displayName: displayName)
        alert.addButton(withTitle: "Retry Restoration")
        let quitAnywayButton = alert.addButton(withTitle: "Quit Anyway")
        quitAnywayButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel Quit")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .retry
        case .alertSecondButtonReturn:
            return .quitAnyway
        default:
            return .cancel
        }
    }

    static func restorationFailureText(
        _ result: ProcessRestorationResult,
        displayName: (String) -> String
    ) -> String {
        let summary = MenuBarView.lifecycleFailureMessage(result)
        let details = result.failures.map { failure in
            let processList = failure.processIdentifiers.map(String.init).joined(separator: ", ")
            return "\(displayName(failure.bundleIdentifier)) (processes: \(processList))"
        }.joined(separator: "\n")
        return summary
            + "\n\n"
            + details
            + "\n\nIf you quit anyway, Tempra's safety processes restore the remaining "
            + "managed processes as soon as Tempra exits."
    }
}

enum TerminationFailureAction: Sendable {
    case retry
    case quitAnyway
    case cancel
}

@MainActor
final class ApplicationTerminationCoordinator {
    private var hasStarted = false
    private var pendingReplies: [@MainActor @Sendable (Bool) -> Void] = []

    func begin(
        shutdown: @escaping @MainActor @Sendable () async -> ProcessRestorationResult,
        presentFailure: @escaping @MainActor @Sendable (
            ProcessRestorationResult
        ) -> TerminationFailureAction,
        invalidate: @escaping @MainActor @Sendable () -> Void,
        reply: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        pendingReplies.append(reply)
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            let shouldTerminate = await resolve(
                shutdown: shutdown,
                presentFailure: presentFailure
            )
            if shouldTerminate {
                invalidate()
            } else {
                hasStarted = false
            }
            let replies = pendingReplies
            pendingReplies.removeAll(keepingCapacity: true)
            replies.forEach { $0(shouldTerminate) }
        }
    }

    func resolve(
        shutdown: @escaping @MainActor @Sendable () async -> ProcessRestorationResult,
        presentFailure: @escaping @MainActor @Sendable (
            ProcessRestorationResult
        ) -> TerminationFailureAction
    ) async -> Bool {
        while true {
            let result = await shutdown()
            if result.succeeded { return true }
            switch presentFailure(result) {
            case .retry:
                continue
            case .quitAnyway:
                return true
            case .cancel:
                return false
            }
        }
    }
}
