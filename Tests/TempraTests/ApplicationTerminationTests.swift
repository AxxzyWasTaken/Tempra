import Testing
@testable import Tempra

@Suite("Application termination")
@MainActor
struct ApplicationTerminationTests {
    @Test("Termination retries restoration failures before allowing quit")
    func retriesThenTerminates() async {
        let coordinator = ApplicationTerminationCoordinator()
        var shutdownAttempts = 0
        var presentedFailures = 0

        let shouldTerminate = await coordinator.resolve(
            shutdown: {
                shutdownAttempts += 1
                return shutdownAttempts == 1 ? failureResult : .success
            },
            presentFailure: { result in
                presentedFailures += 1
                #expect(!result.succeeded)
                return .retry
            }
        )

        #expect(shouldTerminate)
        #expect(shutdownAttempts == 2)
        #expect(presentedFailures == 1)
    }

    @Test("Cancel keeps the application alive after restoration fails")
    func cancellationBlocksTermination() async {
        let coordinator = ApplicationTerminationCoordinator()
        var shutdownAttempts = 0

        let shouldTerminate = await coordinator.resolve(
            shutdown: {
                shutdownAttempts += 1
                return failureResult
            },
            presentFailure: { _ in .cancel }
        )

        #expect(!shouldTerminate)
        #expect(shutdownAttempts == 1)
    }

    @Test("Quit Anyway ends the application without successful restoration")
    func quitAnywayTerminates() async {
        let coordinator = ApplicationTerminationCoordinator()
        var shutdownAttempts = 0

        let shouldTerminate = await coordinator.resolve(
            shutdown: {
                shutdownAttempts += 1
                return failureResult
            },
            presentFailure: { _ in .quitAnyway }
        )

        #expect(shouldTerminate)
        #expect(shutdownAttempts == 1)
    }

    @Test("Retry followed by Quit Anyway attempts another restoration first")
    func retryThenQuitAnyway() async {
        let coordinator = ApplicationTerminationCoordinator()
        var shutdownAttempts = 0
        var presentedFailures = 0

        let shouldTerminate = await coordinator.resolve(
            shutdown: {
                shutdownAttempts += 1
                return failureResult
            },
            presentFailure: { _ in
                presentedFailures += 1
                return presentedFailures == 1 ? .retry : .quitAnyway
            }
        )

        #expect(shouldTerminate)
        #expect(shutdownAttempts == 2)
        #expect(presentedFailures == 2)
    }

    @Test("The quit alert names the app and the cause of the failure")
    func quitAlertTextNamesAppAndCause() {
        let result = ProcessRestorationResult(failures: [ProcessRestorationFailure(
            bundleIdentifier: "example.app",
            stoppedProcesses: [ProcessIdentity(pid: 42, startTimeMicroseconds: 100)],
            backgroundPriorityProcesses: [],
            resumeFailureDescription: "The privileged helper connection failed."
        )])

        let text = AppDelegate.restorationFailureText(result) { identifier in
            identifier == "example.app" ? "Example" : identifier
        }

        #expect(text.hasPrefix(
            "Tempra could not resume 1 process in 1 app. "
                + "The privileged helper connection failed. Management remains blocked."
        ))
        #expect(text.contains("Example (processes: 42)"))
        #expect(!text.contains("example.app"))
    }

    private var failureResult: ProcessRestorationResult {
        ProcessRestorationResult(failures: [ProcessRestorationFailure(
            bundleIdentifier: "example.app",
            stoppedProcesses: [ProcessIdentity(pid: 42, startTimeMicroseconds: 100)],
            backgroundPriorityProcesses: []
        )])
    }
}
