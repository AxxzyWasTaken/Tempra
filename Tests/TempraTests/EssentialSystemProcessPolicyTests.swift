import AppKit
import Testing
@testable import Tempra

@Suite("Background process visibility")
struct BackgroundProcessPolicyTests {
    @Test("Default visibility keeps background and protected system apps hidden")
    func defaultVisibility() {
        #expect(!BackgroundProcessPolicy.shouldIncludeApplication(
            bundleIdentifier: "com.apple.finder",
            activationPolicy: .regular,
            includesBackgroundProcesses: false
        ))
        #expect(!BackgroundProcessPolicy.shouldIncludeApplication(
            bundleIdentifier: "example.background-agent",
            activationPolicy: .prohibited,
            includesBackgroundProcesses: false
        ))
        #expect(BackgroundProcessPolicy.shouldIncludeApplication(
            bundleIdentifier: "example.foreground-app",
            activationPolicy: .regular,
            includesBackgroundProcesses: false
        ))
    }

    @Test("Enabled visibility includes every NSWorkspace application")
    func enabledVisibility() {
        #expect(BackgroundProcessPolicy.shouldIncludeApplication(
            bundleIdentifier: "com.apple.finder",
            activationPolicy: .regular,
            includesBackgroundProcesses: true
        ))
        #expect(BackgroundProcessPolicy.shouldIncludeApplication(
            bundleIdentifier: "example.background-agent",
            activationPolicy: .prohibited,
            includesBackgroundProcesses: true
        ))
    }

    @Test("Background identities are stable and monitor-only")
    func backgroundIdentity() {
        let first = BackgroundProcessPolicy.identifier(command: "/usr/libexec/logd", pid: 10)
        let second = BackgroundProcessPolicy.identifier(command: "/usr/libexec/logd", pid: 20)
        let unnamed = BackgroundProcessPolicy.identifier(command: "", pid: 30)

        #expect(first == second)
        #expect(first != unnamed)
        #expect(BackgroundProcessPolicy.isMonitorOnlyIdentifier(first))
        #expect(BackgroundProcessPolicy.isMonitorOnlyIdentifier("com.apple.finder"))
        #expect(!BackgroundProcessPolicy.isMonitorOnlyIdentifier("example.foreground-app"))
        #expect(BackgroundProcessPolicy.displayName(
            command: "/usr/libexec/logd",
            pid: 10
        ) == "logd")
    }

    @Test("Process-table parsing preserves commands containing spaces")
    func processTableParsing() throws {
        let entries = ProcessTableEntry.parse(
            """
                1     0     0   1.7 /sbin/launchd
               42     1   501   0.3 /Applications/Example App.app/Contents/MacOS/Example App
            malformed row
            """
        )

        #expect(entries.count == 2)
        let launchd = try #require(entries.first)
        #expect(launchd.pid == 1)
        #expect(launchd.userID == 0)
        #expect(launchd.cpuPercent == 1.7)
        #expect(launchd.command == "/sbin/launchd")
        #expect(entries[1].command == "/Applications/Example App.app/Contents/MacOS/Example App")
    }

    @Test("Live sampler includes root-owned launchd as monitor-only")
    @MainActor
    func liveRootDaemonVisibility() {
        let apps = ProcessMonitor().sample(includingEssentialSystemProcesses: true)
        let launchdIdentifier = BackgroundProcessPolicy.identifier(
            command: "/sbin/launchd",
            pid: 1
        )

        #expect(apps.contains {
            $0.bundleIdentifier == launchdIdentifier
                && $0.processIdentifiers.contains(1)
                && $0.isSystemProcess
        })
    }
}
