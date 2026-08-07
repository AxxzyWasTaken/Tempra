import Darwin
import Foundation
import Testing
@testable import Tempra

@Suite("Process crash watchdog")
struct ProcessCrashWatchdogTests {
    @Test("The helper confirms its automatic-resume deadline before a stop")
    func helperAcknowledgesAutomaticResumeDeadline() async throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #if DEBUG
        let buildConfiguration = "Debug"
        #else
        let buildConfiguration = "Release"
        #endif
        let helperURL = repositoryURL
            .appendingPathComponent(
                ".build/out/Products/\(buildConfiguration)/TempraWatchdog"
            )
        try #require(FileManager.default.isExecutableFile(atPath: helperURL.path))
        let identity = try #require(
            LiveProcessSystemController.currentIdentity(for: getpid())
        )
        let watchdog = ProcessCrashWatchdog(helperURLProvider: { helperURL })

        do {
            try await watchdog.prepareToStop([identity])
            try await watchdog.armAutomaticResume([identity: 0.1])
            try await watchdog.synchronizeAutomaticResume([:])
        } catch {
            await watchdog.disarm()
            throw error
        }
        await watchdog.disarm()
    }

    @Test("A repeated arm replaces the earlier automatic-resume deadline")
    func repeatedArmReplacesEarlierDeadline() async throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #if DEBUG
        let buildConfiguration = "Debug"
        #else
        let buildConfiguration = "Release"
        #endif
        let helperURL = repositoryURL
            .appendingPathComponent(
                ".build/out/Products/\(buildConfiguration)/TempraWatchdog"
            )
        try #require(FileManager.default.isExecutableFile(atPath: helperURL.path))

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
        let watchdog = ProcessCrashWatchdog(helperURLProvider: { helperURL })

        do {
            try await watchdog.prepareToStop([identity])
            try await watchdog.armAutomaticResume([identity: 0.25])
            try await Task.sleep(for: .milliseconds(120))
            try await watchdog.armAutomaticResume([identity: 0.4])
            try #require(kill(pid, SIGSTOP) == 0)

            try await Task.sleep(for: .milliseconds(180))
            let stateAfterEarlierDeadline = try #require(
                LiveProcessSystemController.bsdInfo(for: pid)
            )
            #expect(UInt32(stateAfterEarlierDeadline.pbi_status) == UInt32(SSTOP))

            try await Task.sleep(for: .milliseconds(280))
            let stateAfterReplacementDeadline = try #require(
                LiveProcessSystemController.bsdInfo(for: pid)
            )
            #expect(UInt32(stateAfterReplacementDeadline.pbi_status) != UInt32(SSTOP))
            try await watchdog.synchronizeAutomaticResume([:])
        } catch {
            await watchdog.disarm()
            throw error
        }
        await watchdog.disarm()
    }
}
