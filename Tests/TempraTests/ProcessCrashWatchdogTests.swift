import Darwin
import Foundation
import Testing
@testable import Tempra

/// Serialized for the same reason as the guardian suite: these tests stop and
/// resume real processes and wait on real deadlines.
@Suite("Process crash watchdog", .serialized)
struct ProcessCrashWatchdogTests {
    /// The built `TempraWatchdog` executable, found relative to the loaded test
    /// bundle rather than assembled from a build configuration name.
    ///
    /// SwiftPM does not promise one build layout: locally the products land in
    /// `.build/out/Products/Debug`, on a clean checkout in
    /// `.build/<triple>/debug`, and the test host process is a toolchain
    /// binary, so `Bundle.main` points into Xcode. Asking the dynamic linker
    /// where this test bundle itself came from is the one answer that holds in
    /// every layout.
    private static func watchdogExecutableURL() throws -> URL {
        var info = Dl_info()
        try #require(dladdr(#dsohandle, &info) != 0)
        let imagePath = try #require(info.dli_fname)
        var directory = URL(fileURLWithPath: String(cString: imagePath))
            .deletingLastPathComponent()
        // An .xctest bundle nests the binary in Contents/MacOS; the products
        // directory that also holds TempraWatchdog is three levels up.
        while directory.pathExtension != "xctest", directory.path != "/" {
            directory = directory.deletingLastPathComponent()
        }
        let productsURL = directory.path == "/"
            ? URL(fileURLWithPath: String(cString: imagePath))
                .deletingLastPathComponent()
            : directory.deletingLastPathComponent()
        let helperURL = productsURL.appendingPathComponent("TempraWatchdog")
        try #require(
            FileManager.default.isExecutableFile(atPath: helperURL.path),
            "TempraWatchdog is not next to the test bundle at \(productsURL.path)"
        )
        return helperURL
    }

    @Test("The helper confirms its automatic-resume deadline before a stop")
    func helperAcknowledgesAutomaticResumeDeadline() async throws {
        let helperURL = try Self.watchdogExecutableURL()
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
        let helperURL = try Self.watchdogExecutableURL()

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
