import Darwin
import Testing
@testable import Tempra

@Suite("Process system routing")
struct ProcessSystemControllerTests {
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
}
