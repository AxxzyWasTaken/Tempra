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

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try AppStore { error in
                Self.presentPersistenceFailure(error)
            }
            self.store = store
            let menuPanelCoordinator = MenuPanelCoordinator(store: store)
            self.menuPanelCoordinator = menuPanelCoordinator
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
                Self.presentRestorationFailure(result)
            },
            invalidate: { [weak self] in
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
        _ result: ProcessRestorationResult
    ) -> TerminationFailureAction {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Tempra could not safely quit"
        let details = result.failures.map { failure in
            let processList = failure.processIdentifiers.map(String.init).joined(separator: ", ")
            return "\(failure.bundleIdentifier) (processes: \(processList))"
        }.joined(separator: "\n")
        alert.informativeText = "Tempra could not restore every managed process. "
            + "It will remain open so no application is silently left paused.\n\n"
            + details
        alert.addButton(withTitle: "Retry Restoration")
        alert.addButton(withTitle: "Cancel Quit")
        return alert.runModal() == .alertFirstButtonReturn ? .retry : .cancel
    }
}

enum TerminationFailureAction: Sendable {
    case retry
    case cancel
}

@MainActor
final class ApplicationTerminationCoordinator {
    private var hasStarted = false

    func begin(
        shutdown: @escaping @MainActor @Sendable () async -> ProcessRestorationResult,
        presentFailure: @escaping @MainActor @Sendable (
            ProcessRestorationResult
        ) -> TerminationFailureAction,
        invalidate: @escaping @MainActor @Sendable () -> Void,
        reply: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
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
            reply(shouldTerminate)
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
            if presentFailure(result) == .cancel { return false }
        }
    }
}
