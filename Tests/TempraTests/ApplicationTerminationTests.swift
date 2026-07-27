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

    private var failureResult: ProcessRestorationResult {
        ProcessRestorationResult(failures: [ProcessRestorationFailure(
            bundleIdentifier: "example.app",
            stoppedProcesses: [ProcessIdentity(pid: 42, startTimeMicroseconds: 100)],
            backgroundPriorityProcesses: []
        )])
    }
}
