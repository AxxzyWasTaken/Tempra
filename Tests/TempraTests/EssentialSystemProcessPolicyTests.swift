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

    @Test("User-owned service applications can be managed")
    func userOwnedServiceManagement() {
        let userID = getuid()

        #expect(!BackgroundProcessPolicy.isMonitorOnlyApplication(
            bundleIdentifier: "com.apple.WebKit.GPU",
            userID: userID,
            currentUserID: userID
        ))
        #expect(BackgroundProcessPolicy.isServiceApplication(
            activationPolicy: .accessory
        ))
        #expect(BackgroundProcessPolicy.isServiceApplication(
            activationPolicy: .prohibited
        ))
    }

    @Test("Protected and foreign-user applications remain monitor-only")
    func protectedApplicationManagement() {
        let userID = getuid()

        #expect(BackgroundProcessPolicy.isMonitorOnlyApplication(
            bundleIdentifier: "com.apple.finder",
            userID: userID,
            currentUserID: userID
        ))
        #expect(BackgroundProcessPolicy.isMonitorOnlyApplication(
            bundleIdentifier: "example.foreign-service",
            userID: userID &+ 1,
            currentUserID: userID
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

    @Test("WindowServer is recognized across executable path variants")
    func windowServerIdentity() {
        let direct = BackgroundProcessPolicy.identifier(
            command: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            pid: 100
        )
        let versioned = BackgroundProcessPolicy.identifier(
            command: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
            pid: 100
        )

        #expect(SystemProcessRulePolicy.isWindowServer(bundleIdentifier: direct))
        #expect(SystemProcessRulePolicy.isWindowServer(bundleIdentifier: versioned))
        #expect(SystemProcessRulePolicy.isWindowServer(
            bundleIdentifier: "com.apple.WindowServer"
        ))
        #expect(!SystemProcessRulePolicy.isWindowServer(
            bundleIdentifier: BackgroundProcessPolicy.identifier(
                command: "/usr/libexec/logd",
                pid: 101
            )
        ))
    }

    @Test("User-owned background identities are stable and editable")
    func userOwnedBackgroundIdentity() {
        let command = "/Users/example/Library/Application Support/CrossOver/wine64-preloader"
        let first = BackgroundProcessPolicy.userOwnedIdentifier(command: command, pid: 10)
        let second = BackgroundProcessPolicy.userOwnedIdentifier(command: command, pid: 20)

        #expect(first == second)
        #expect(BackgroundProcessPolicy.isUserOwnedIdentifier(first))
        #expect(BackgroundProcessPolicy.isBackgroundIdentifier(first))
        #expect(!BackgroundProcessPolicy.isMonitorOnlyIdentifier(first))
        #expect(!BackgroundProcessPolicy.isMonitorOnlyBackgroundProcess(
            userID: 501,
            currentUserID: 501,
            hasProcessIdentity: true
        ))
        #expect(BackgroundProcessPolicy.isMonitorOnlyBackgroundProcess(
            userID: 501,
            currentUserID: 501,
            hasProcessIdentity: false
        ))
        #expect(BackgroundProcessPolicy.isMonitorOnlyBackgroundProcess(
            userID: 0,
            currentUserID: 501,
            hasProcessIdentity: true
        ))
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
    func liveRootDaemonVisibility() async {
        let apps = await ProcessMonitor().sample(includingEssentialSystemProcesses: true)
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
