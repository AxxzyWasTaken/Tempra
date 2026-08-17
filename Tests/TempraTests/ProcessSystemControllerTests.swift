import Darwin
import Foundation
import Testing
@testable import Tempra

@Suite("Process system routing")
struct ProcessSystemControllerTests {
    @Test("User-owned stopping uses a direct signal")
    func userOwnedStoppingUsesDirectSignal() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["10"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        defer {
            _ = kill(pid, SIGCONT)
            if sleeper.isRunning {
                sleeper.terminate()
                sleeper.waitUntilExit()
            }
        }

        let identity = try #require(
            LiveProcessSystemController.currentIdentity(for: pid)
        )
        let controller = LiveProcessSystemController()

        let result = await controller.stop(
            [identity],
            automaticResumeAfter: 0.1
        )

        #expect(result.applied == [identity])
        #expect(result.stale.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(await eventuallyStatus(of: pid, isStopped: true))
    }

    @Test("User-owned restoration does not depend on the process guardian")
    func userOwnedRestorationUsesDirectSignal() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["10"]
        try sleeper.run()
        let pid = sleeper.processIdentifier
        defer {
            _ = kill(pid, SIGCONT)
            if sleeper.isRunning {
                sleeper.terminate()
                sleeper.waitUntilExit()
            }
        }

        let identity = try #require(
            LiveProcessSystemController.currentIdentity(for: pid)
        )
        try #require(kill(pid, SIGSTOP) == 0)
        #expect(await eventuallyStatus(of: pid, isStopped: true))

        let controller = LiveProcessSystemController()
        let result = await controller.resume([identity])

        #expect(result.applied == [identity])
        #expect(result.stale.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(await eventuallyStatus(of: pid, isStopped: false))
    }

    @Test("Exited processes do not require privileged priority restoration")
    func exitedProcessesDoNotRequirePrivilegedPriorityRestoration() async {
        let staleProcess = ProcessIdentity(
            pid: getpid(),
            startTimeMicroseconds: 0
        )
        let controller = RoutedProcessSystemController()

        let result = await controller.restorePriority([staleProcess])

        #expect(result.applied.isEmpty)
        #expect(result.stale == [staleProcess])
        #expect(result.failed.isEmpty)
        #expect(result.failureDescription == nil)
    }

    private func eventuallyStatus(
        of pid: pid_t,
        isStopped expectedStatus: Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if let info = LiveProcessSystemController.bsdInfo(for: pid),
               (UInt32(info.pbi_status) == UInt32(SSTOP)) == expectedStatus {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
