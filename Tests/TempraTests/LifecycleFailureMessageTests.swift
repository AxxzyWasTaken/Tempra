import Testing
@testable import Tempra

@Suite("Lifecycle failure message")
struct LifecycleFailureMessageTests {
    @Test("A resume failure is described as a resume failure")
    func resumeFailureMessage() {
        let result = ProcessRestorationResult(failures: [ProcessRestorationFailure(
            bundleIdentifier: "example.resume",
            stoppedProcesses: [identity(5_001)],
            backgroundPriorityProcesses: [],
            resumeFailureDescription: "The privileged helper connection failed."
        )])

        #expect(
            MenuBarView.lifecycleFailureMessage(result)
                == "Tempra could not resume 1 process in 1 app. "
                    + "The privileged helper connection failed. Management remains blocked."
        )
    }

    @Test("A priority failure is not described as a resume failure")
    func priorityFailureMessage() {
        let result = ProcessRestorationResult(failures: [ProcessRestorationFailure(
            bundleIdentifier: "example.priority",
            stoppedProcesses: [],
            backgroundPriorityProcesses: [identity(5_002)],
            priorityFailureDescription: "The process priority restore request failed."
        )])

        #expect(
            MenuBarView.lifecycleFailureMessage(result)
                == "Tempra could not restore normal priority for 1 process in 1 app. "
                    + "The process priority restore request failed. Management remains blocked."
        )
    }

    @Test("Combined restoration failures report both operations")
    func combinedFailureMessage() {
        let sharedDetail = "The privileged helper did not respond in time."
        let result = ProcessRestorationResult(failures: [
            ProcessRestorationFailure(
                bundleIdentifier: "example.first",
                stoppedProcesses: [identity(5_003), identity(5_004)],
                backgroundPriorityProcesses: [identity(5_003)],
                resumeFailureDescription: sharedDetail,
                priorityFailureDescription: sharedDetail
            ),
            ProcessRestorationFailure(
                bundleIdentifier: "example.second",
                stoppedProcesses: [identity(5_005)],
                backgroundPriorityProcesses: [],
                resumeFailureDescription: sharedDetail
            )
        ])

        #expect(
            MenuBarView.lifecycleFailureMessage(result)
                == "Tempra could not resume 3 processes in 2 apps. "
                    + "Tempra could not restore normal priority for 1 process in 1 app. "
                    + "The privileged helper did not respond in time. "
                    + "Management remains blocked."
        )
    }

    private func identity(_ pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeMicroseconds: UInt64(pid) * 1_000)
    }
}
