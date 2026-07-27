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
    private let terminationCoordinator = ApplicationTerminationCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = MenuPanelCoordinator(store: AppStore.shared)
        menuPanelCoordinator = coordinator
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        menuPanelCoordinator?.closePanels()
        terminationCoordinator.begin(
            shutdown: {
                await AppStore.shared.shutdown()
            },
            invalidate: { [weak self] in
                self?.menuPanelCoordinator?.invalidate()
                self?.menuPanelCoordinator = nil
            },
            reply: {
                sender.reply(toApplicationShouldTerminate: true)
            }
        )
        return .terminateLater
    }
}

@MainActor
final class ApplicationTerminationCoordinator {
    private var hasStarted = false

    func begin(
        shutdown: @escaping @MainActor @Sendable () async -> Void,
        invalidate: @escaping @MainActor @Sendable () -> Void,
        reply: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            await shutdown()
            invalidate()
            reply()
        }
    }
}
