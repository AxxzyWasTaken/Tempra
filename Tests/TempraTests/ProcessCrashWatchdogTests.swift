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
}
