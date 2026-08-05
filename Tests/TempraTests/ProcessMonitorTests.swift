import AppKit
import Darwin
import Foundation
import Testing
@testable import Tempra

@Suite("Process monitor metadata cache")
struct ProcessMonitorTests {
    @Test("An accessory display window is a foreground overlay")
    func accessoryDisplayWindowIsForegroundOverlay() {
        let processIdentifier: pid_t = 200
        let descriptor = RunningApplicationDescriptor(
            bundleIdentifier: "example.brightness-overlay",
            localizedName: "Brightness Overlay",
            bundleURL: URL(fileURLWithPath: "/Applications/Brightness Overlay.app"),
            processIdentifier: processIdentifier,
            activationPolicyRawValue: NSApplication.ActivationPolicy.accessory.rawValue,
            isHidden: false
        )
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [WindowVisibilityRecord(
                ownerPID: processIdentifier,
                bounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                layer: 1_000,
                alpha: 1
            )],
            screenBounds: [CGRect(x: 0, y: 0, width: 1_000, height: 800)]
        )

        #expect(ForegroundApplicationPolicy.isForegroundOverlay(
            descriptor,
            windowSnapshot: snapshot
        ))
        #expect(ForegroundApplicationPolicy.displayOverlayProcessIdentifiers(
            applications: [descriptor],
            windowSnapshot: snapshot
        ) == [processIdentifier])
    }

    @Test("A regular full-screen app is not a foreground overlay")
    func regularFullScreenAppIsNotForegroundOverlay() {
        let processIdentifier: pid_t = 200
        let descriptor = RunningApplicationDescriptor(
            bundleIdentifier: "example.full-screen-app",
            localizedName: "Full-screen App",
            bundleURL: URL(fileURLWithPath: "/Applications/Full-screen App.app"),
            processIdentifier: processIdentifier,
            activationPolicyRawValue: NSApplication.ActivationPolicy.regular.rawValue,
            isHidden: false
        )
        let snapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [WindowVisibilityRecord(
                ownerPID: processIdentifier,
                bounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                layer: 0,
                alpha: 1
            )],
            screenBounds: [CGRect(x: 0, y: 0, width: 1_000, height: 800)]
        )

        #expect(!ForegroundApplicationPolicy.isForegroundOverlay(
            descriptor,
            windowSnapshot: snapshot
        ))
        #expect(ForegroundApplicationPolicy.displayOverlayProcessIdentifiers(
            applications: [descriptor],
            windowSnapshot: snapshot
        ).isEmpty)
    }

    @Test("A foreground overlay preserves the preceding app")
    func foregroundOverlayPreservesPrecedingApp() {
        var tracker = ForegroundApplicationTracker()

        #expect(tracker.protectedIdentifier(
            frontmostIdentifier: "example.editor",
            isForegroundOverlay: false
        ) == nil)
        #expect(tracker.protectedIdentifier(
            frontmostIdentifier: "example.brightness-overlay",
            isForegroundOverlay: true
        ) == "example.editor")
    }

    @Test("A brightness overlay keeps the underlying foreground app protected")
    func brightnessOverlayKeepsUnderlyingAppProtected() async throws {
        let editorIdentity = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000_000)
        let overlayIdentity = ProcessIdentity(pid: 200, startTimeMicroseconds: 2_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [
                editorIdentity.pid: snapshot(editorIdentity, executableName: "Editor"),
                overlayIdentity.pid: snapshot(
                    overlayIdentity,
                    executableName: "BrightnessOverlay"
                ),
            ],
            paths: [
                editorIdentity.pid: appExecutable("Editor"),
                overlayIdentity.pid: appExecutable(
                    "Brightness Overlay",
                    component: "BrightnessOverlay"
                ),
            ]
        )
        let editor = RunningApplicationDescriptor(
            bundleIdentifier: "example.editor",
            localizedName: "Editor",
            bundleURL: URL(fileURLWithPath: "/Applications/Editor.app"),
            processIdentifier: editorIdentity.pid,
            activationPolicyRawValue: NSApplication.ActivationPolicy.regular.rawValue,
            isHidden: false
        )
        let overlay = RunningApplicationDescriptor(
            bundleIdentifier: "example.brightness-overlay",
            localizedName: "Brightness Overlay",
            bundleURL: URL(fileURLWithPath: "/Applications/Brightness Overlay.app"),
            processIdentifier: overlayIdentity.pid,
            activationPolicyRawValue: NSApplication.ActivationPolicy.accessory.rawValue,
            isHidden: false
        )
        let visibilitySnapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                WindowVisibilityRecord(
                    ownerPID: overlayIdentity.pid,
                    bounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                    layer: 1_000,
                    alpha: 1
                ),
                WindowVisibilityRecord(
                    ownerPID: editorIdentity.pid,
                    bounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                    layer: 0,
                    alpha: 1
                ),
            ],
            screenBounds: [CGRect(x: 0, y: 0, width: 1_000, height: 800)]
        )
        let monitor = ProcessMonitor(
            processReader: reader,
            currentUserID: 501,
            uptime: { 1 },
            audioProcessIdentifiers: { [] },
            windowSnapshot: { visibilitySnapshot }
        )

        _ = await monitor.sample(inventory: ApplicationInventory(
            applications: [editor, overlay],
            frontmostBundleIdentifier: editor.bundleIdentifier,
            ownBundleIdentifier: nil
        ))
        let overlayFrontmostSample = await monitor.sample(inventory: ApplicationInventory(
            applications: [editor, overlay],
            frontmostBundleIdentifier: overlay.bundleIdentifier,
            ownBundleIdentifier: nil
        ))
        let editorResult = try #require(overlayFrontmostSample.first {
            $0.bundleIdentifier == editor.bundleIdentifier
        })

        #expect(!editorResult.isFrontmost)
        #expect(editorResult.isProtectedByForegroundOverlay)
        #expect(editorResult.windowVisibility == .visible)
    }

    @Test("Stable metadata is cached while CPU counters remain current")
    func stableMetadataAndCurrentCPU() async throws {
        let identity = ProcessIdentity(pid: 100, startTimeMicroseconds: 2_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [100: snapshot(identity, cpuNanoseconds: 1_000_000_000)],
            paths: [100: appExecutable("Example")]
        )
        let clock = StubUptime(value: 10)
        let monitor = makeMonitor(reader: reader, clock: clock)
        let inventory = inventory(app("Example", pid: 100))

        let initial = try #require(await monitor.sample(inventory: inventory).first)
        #expect(initial.cpuPercent == 0)
        #expect(initial.residentMemoryBytes == 128 * 1_024 * 1_024)
        #expect(initial.launchedAt?.timeIntervalSince1970 == 2)
        #expect(reader.pathReads[100] == 1)
        #expect(monitor.cachedMetadataCount == 1)

        reader.snapshots[100] = snapshot(
            identity,
            cpuNanoseconds: 1_500_000_000,
            residentMemoryBytes: 160 * 1_024 * 1_024
        )
        clock.value = 11
        let updated = try #require(await monitor.sample(inventory: inventory).first)

        #expect(abs(updated.cpuPercent - 50) < 0.000_000_1)
        #expect(updated.residentMemoryBytes == 160 * 1_024 * 1_024)
        #expect(reader.pathReads[100] == 1)
        #expect(monitor.cachedMetadataCount == 1)
    }

    @Test("A reset baseline is measured again instead of caching zero CPU")
    func resetBaselineIsNotCached() async throws {
        let identity = ProcessIdentity(pid: 100, startTimeMicroseconds: 2_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [100: snapshot(identity, cpuNanoseconds: 1_000_000_000)],
            paths: [100: appExecutable("Example")]
        )
        let clock = StubUptime(value: 1)
        let monitor = ProcessMonitor(
            processReader: reader,
            currentUserID: 501,
            uptime: { clock.value },
            audioProcessIdentifiers: { [] },
            windowSnapshot: { nil },
            processTableReader: {
                (
                    entries: [ProcessTableEntry(
                        pid: 100,
                        parentPID: 1,
                        userID: 501,
                        cpuPercent: 0,
                        command: "/Applications/Example.app/Contents/MacOS/Example"
                    )],
                    samplerPID: 999
                )
            },
            privilegedSnapshotReader: { _ in [:] }
        )
        let appInventory = inventory(app("Example", pid: 100))

        _ = await monitor.sample(
            inventory: appInventory,
            includingEssentialSystemProcesses: true
        )
        reader.snapshots[100] = snapshot(identity, cpuNanoseconds: 2_000_000_000)
        clock.value = 2
        let measured = try #require(await monitor.sample(
            inventory: appInventory,
            includingEssentialSystemProcesses: true
        ).first)
        #expect(abs(measured.cpuPercent - 100) < 0.000_000_1)

        monitor.resetSamplingBaseline()
        reader.snapshots[100] = snapshot(identity, cpuNanoseconds: 3_000_000_000)
        clock.value = 6
        let baseline = try #require(await monitor.sample(
            inventory: appInventory,
            includingEssentialSystemProcesses: true
        ).first)
        #expect(baseline.cpuPercent == 0)

        reader.snapshots[100] = snapshot(identity, cpuNanoseconds: 4_000_000_000)
        clock.value = 7
        let refreshed = try #require(await monitor.sample(
            inventory: appInventory,
            includingEssentialSystemProcesses: true
        ).first)
        #expect(abs(refreshed.cpuPercent - 100) < 0.000_000_1)
    }

    @Test("New processes are cached and exited processes are removed")
    func newAndExitedProcesses() async {
        let mainIdentity = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000_000)
        let helperIdentity = ProcessIdentity(pid: 200, startTimeMicroseconds: 2_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [100: snapshot(mainIdentity)],
            paths: [
                100: appExecutable("Example"),
                200: "/usr/libexec/example-helper"
            ]
        )
        let clock = StubUptime(value: 1)
        let monitor = makeMonitor(reader: reader, clock: clock)
        let appInventory = inventory(app("Example", pid: 100))

        _ = await monitor.sample(inventory: appInventory)
        #expect(monitor.cachedMetadataCount == 1)

        reader.snapshots[200] = snapshot(helperIdentity, parentPID: 100)
        clock.value = 2
        let withHelper = await monitor.sample(inventory: appInventory)
        #expect(withHelper.first?.processIdentifiers == [100, 200])
        #expect(monitor.cachedMetadataCount == 2)
        #expect(reader.pathReads[200] == 1)

        reader.snapshots[200] = snapshot(helperIdentity, parentPID: 1)
        clock.value = 3
        let reparentedHelper = await monitor.sample(inventory: appInventory)
        #expect(reparentedHelper.first?.processIdentifiers == [100])
        #expect(reader.pathReads[200] == 1)

        reader.snapshots.removeValue(forKey: 200)
        clock.value = 4
        let withoutHelper = await monitor.sample(inventory: appInventory)
        #expect(withoutHelper.first?.processIdentifiers == [100])
        #expect(monitor.cachedMetadataCount == 1)

        reader.snapshots.removeAll()
        clock.value = 5
        let emptySample = await monitor.sample(inventory: appInventory)
        #expect(emptySample.isEmpty)
        #expect(monitor.cachedMetadataCount == 0)
    }

    @Test("PID reuse replaces metadata and resets the CPU baseline")
    func pidReuse() async throws {
        let firstIdentity = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000_000)
        let replacementIdentity = ProcessIdentity(pid: 100, startTimeMicroseconds: 9_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [100: snapshot(firstIdentity, cpuNanoseconds: 8_000_000_000)],
            paths: [100: appExecutable("Example")]
        )
        let clock = StubUptime(value: 1)
        let monitor = makeMonitor(reader: reader, clock: clock)
        let appInventory = inventory(app("Example", pid: 100))

        _ = await monitor.sample(inventory: appInventory)
        reader.snapshots[100] = snapshot(replacementIdentity, cpuNanoseconds: 100_000_000)
        reader.paths[100] = "/Applications/Example.app/Contents/MacOS/Replacement"
        clock.value = 2

        let replacement = try #require(await monitor.sample(inventory: appInventory).first)
        #expect(replacement.processIdentities == [replacementIdentity])
        #expect(replacement.launchedAt?.timeIntervalSince1970 == 9)
        #expect(replacement.cpuPercent == 0)
        #expect(reader.pathReads[100] == 2)
        #expect(monitor.cachedMetadataCount == 1)
    }

    @Test("Forked helpers join every instance and use the newest app launch")
    func forkedHelperAssignment() async throws {
        let firstMain = ProcessIdentity(pid: 100, startTimeMicroseconds: 3_000_000)
        let secondMain = ProcessIdentity(pid: 101, startTimeMicroseconds: 2_000_000)
        let helper = ProcessIdentity(pid: 200, startTimeMicroseconds: 4_000_000)
        let helperChild = ProcessIdentity(pid: 201, startTimeMicroseconds: 5_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [
                100: snapshot(firstMain),
                101: snapshot(secondMain)
            ],
            paths: [
                100: appExecutable("Example"),
                101: appExecutable("Example"),
                200: "/usr/libexec/example-helper",
                201: "/tmp/example-helper-child"
            ]
        )
        let clock = StubUptime(value: 1)
        let monitor = makeMonitor(
            reader: reader,
            clock: clock,
            audioPIDs: [200],
            networkStates: [helperChild: .active]
        )
        let appInventory = inventory(
            app("Example", pid: 100),
            app("Example", pid: 101)
        )

        let beforeFork = try #require(await monitor.sample(inventory: appInventory).first)
        #expect(beforeFork.processIdentifiers == [100, 101])

        reader.snapshots[200] = snapshot(helper, parentPID: 100)
        reader.snapshots[201] = snapshot(helperChild, parentPID: 200)
        clock.value = 2
        let afterFork = try #require(await monitor.sample(inventory: appInventory).first)

        #expect(afterFork.processIdentifiers == [100, 101, 200, 201])
        #expect(Set(afterFork.processIdentities) == [firstMain, secondMain, helper, helperChild])
        #expect(afterFork.residentMemoryBytes == 512 * 1_024 * 1_024)
        #expect(afterFork.launchedAt?.timeIntervalSince1970 == 3)
        #expect(afterFork.isPlayingAudio)
        let samplesByIdentity = Dictionary(
            uniqueKeysWithValues: afterFork.processSamples.map { ($0.identity, $0) }
        )
        #expect(samplesByIdentity[firstMain]?.isMainProcess == true)
        #expect(samplesByIdentity[secondMain]?.isMainProcess == true)
        #expect(samplesByIdentity[helper]?.isMainProcess == false)
        #expect(samplesByIdentity[helper]?.isPlayingAudio == true)
        #expect(samplesByIdentity[helper]?.hasCPUMeasurement == false)
        #expect(samplesByIdentity[helperChild]?.networkActivity == .active)
    }

    @Test("User-owned system extensions remain controllable services")
    func userOwnedSystemExtension() async throws {
        let pid = getpid()
        let identity = ProcessIdentity(pid: pid, startTimeMicroseconds: 1_000_000)
        let extensionURL = URL(
            fileURLWithPath:
                "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/"
                    + "WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc"
        )
        let reader = StubProcessSnapshotReader(
            snapshots: [pid: snapshot(
                identity,
                executableName: "com.apple.WebKit.GPU"
            )],
            paths: [
                pid: extensionURL
                    .appendingPathComponent("Contents/MacOS/com.apple.WebKit.GPU")
                    .path,
            ]
        )
        let monitor = makeMonitor(reader: reader, clock: StubUptime(value: 1))
        let service = RunningApplicationDescriptor(
            bundleIdentifier: "com.apple.WebKit.GPU",
            localizedName: "WebThumbnailExtension Graphics and Media",
            bundleURL: extensionURL,
            processIdentifier: pid,
            activationPolicyRawValue: NSApplication.ActivationPolicy.accessory.rawValue,
            isHidden: false
        )

        let results = await monitor.sample(
            inventory: inventory(service),
            includingEssentialSystemProcesses: true
        )
        let result = try #require(results.first {
            $0.bundleIdentifier == service.bundleIdentifier
        })

        #expect(result.isService)
        #expect(!result.isSystemProcess)
        #expect(result.processIdentities == [identity])
    }

    @Test("User-owned apps keep window control when their bundle is labeled as system")
    func userOwnedSystemLabeledAppKeepsWindowControl() async throws {
        let processID = getpid()
        let identity = ProcessIdentity(pid: processID, startTimeMicroseconds: 1_000_000)
        let bundleURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let reader = StubProcessSnapshotReader(
            snapshots: [processID: snapshot(identity, executableName: "Finder")],
            paths: [
                processID: bundleURL.appendingPathComponent("Contents/MacOS/Finder").path,
            ]
        )
        let visibilitySnapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                WindowVisibilityRecord(
                    ownerPID: processID,
                    bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                    layer: 0,
                    alpha: 1
                ),
            ],
            screenBounds: [CGRect(x: 0, y: 0, width: 100, height: 100)]
        )
        let monitor = makeMonitor(
            reader: reader,
            clock: StubUptime(value: 1),
            windowVisibilitySnapshot: visibilitySnapshot
        )
        let descriptor = RunningApplicationDescriptor(
            bundleIdentifier: "com.apple.finder",
            localizedName: "Finder",
            bundleURL: bundleURL,
            processIdentifier: processID,
            activationPolicyRawValue: NSApplication.ActivationPolicy.regular.rawValue,
            isHidden: false
        )

        let results = await monitor.sample(
            inventory: inventory(descriptor),
            includingEssentialSystemProcesses: true
        )
        let result = try #require(results.first {
            $0.bundleIdentifier == descriptor.bundleIdentifier
        })

        #expect(result.isSystemProcess)
        #expect(!result.requiresPrivilegedControl)
        #expect(result.windowVisibility == .visible)
    }

    @Test("User-owned CrossOver processes remain controllable without an app bundle")
    func userOwnedCrossOverProcess() async throws {
        let identity = ProcessIdentity(pid: 200, startTimeMicroseconds: 2_000_000)
        let executablePath = "/Users/example/Library/Application Support/"
            + "CrossOver/Bottles/Game/wine64-preloader"
        let reader = StubProcessSnapshotReader(
            snapshots: [200: snapshot(
                identity,
                executableName: "Game.exe"
            )],
            paths: [200: executablePath]
        )
        let monitor = ProcessMonitor(
            processReader: reader,
            currentUserID: 501,
            uptime: { 1 },
            audioProcessIdentifiers: { [] },
            windowSnapshot: { nil },
            processTableReader: {
                (
                    entries: [ProcessTableEntry(
                        pid: 200,
                        parentPID: 1,
                        userID: 501,
                        cpuPercent: 25,
                        command: executablePath
                    )],
                    samplerPID: 999
                )
            }
        )

        let result = try #require(await monitor.sample(
            inventory: inventory(),
            includingEssentialSystemProcesses: true
        ).first)

        #expect(result.bundleIdentifier == BackgroundProcessPolicy.userOwnedIdentifier(
            command: executablePath,
            pid: 200
        ))
        #expect(result.processIdentifiers == [200])
        #expect(result.processIdentities == [identity])
        #expect(result.launchedAt?.timeIntervalSince1970 == 2)
        #expect(result.name == "Game.exe")
        #expect(result.isService)
        #expect(!result.isSystemProcess)
        #expect(!BackgroundProcessPolicy.isMonitorOnlyIdentifier(result.bundleIdentifier))
    }

    @Test("Privileged snapshots make root-owned processes safely controllable")
    func privilegedRootProcessIdentity() async throws {
        let processID: pid_t = 220
        let executablePath = "/usr/libexec/example-root-service"
        let identity = ProcessIdentity(
            pid: processID,
            startTimeMicroseconds: 7_000_000,
            requiresPrivilegedControl: true
        )
        let reader = StubProcessSnapshotReader(snapshots: [:], paths: [:])
        let monitor = ProcessMonitor(
            processReader: reader,
            currentUserID: 501,
            uptime: { 1 },
            audioProcessIdentifiers: { [] },
            windowSnapshot: { nil },
            processTableReader: {
                (
                    entries: [ProcessTableEntry(
                        pid: processID,
                        parentPID: 1,
                        userID: 0,
                        cpuPercent: 12,
                        command: executablePath
                    )],
                    samplerPID: 999
                )
            },
            privilegedSnapshotReader: { requestedPIDs in
                #expect(requestedPIDs == [processID])
                return [processID: ProcessKernelSnapshot(
                    identity: identity,
                    parentPID: 1,
                    userID: 0,
                    executableName: "example-root-service",
                    executablePath: executablePath,
                    totalCPUTimeNanoseconds: 1_000_000_000,
                    residentMemoryBytes: 64 * 1_024 * 1_024
                )]
            }
        )

        let result = try #require(await monitor.sample(
            inventory: inventory(),
            includingEssentialSystemProcesses: true
        ).first)

        #expect(result.isSystemProcess)
        #expect(result.processIdentities == [identity])
        #expect(result.residentMemoryBytes == 64 * 1_024 * 1_024)
        #expect(result.name == "example-root-service")
        #expect(monitor.privilegedAccessError == nil)
    }

    @Test("Window visibility is applied to each app from one snapshot")
    func batchedWindowVisibilityIsAppliedToApps() async throws {
        let firstIdentity = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000_000)
        let secondIdentity = ProcessIdentity(pid: 101, startTimeMicroseconds: 1_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [
                100: snapshot(firstIdentity),
                101: snapshot(secondIdentity),
            ],
            paths: [
                100: appExecutable("First"),
                101: appExecutable("Second"),
            ]
        )
        let visibilitySnapshot = WindowVisibilitySnapshot(
            windowsFrontToBack: [
                WindowVisibilityRecord(
                    ownerPID: 100,
                    bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                    layer: 0,
                    alpha: 1
                ),
                WindowVisibilityRecord(
                    ownerPID: 101,
                    bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                    layer: 0,
                    alpha: 1
                ),
            ],
            screenBounds: [CGRect(x: 0, y: 0, width: 100, height: 100)]
        )
        let monitor = makeMonitor(
            reader: reader,
            clock: StubUptime(value: 1),
            windowVisibilitySnapshot: visibilitySnapshot
        )

        let apps = await monitor.sample(inventory: inventory(
            app("First", pid: 100),
            app("Second", pid: 101)
        ))
        let first = try #require(apps.first { $0.bundleIdentifier == bundleIdentifier("First") })
        let second = try #require(apps.first { $0.bundleIdentifier == bundleIdentifier("Second") })

        #expect(first.windowVisibility == .visible)
        #expect(second.windowVisibility == .covered)
    }

    @Test("Exec and exit events invalidate metadata without stale-path fallback")
    @MainActor
    func execAndExitInvalidation() async throws {
        let firstMain = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000_000)
        let secondMain = ProcessIdentity(pid: 101, startTimeMicroseconds: 1_500_000)
        let helper = ProcessIdentity(pid: 200, startTimeMicroseconds: 2_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [
                100: snapshot(firstMain),
                101: snapshot(secondMain),
                200: snapshot(helper, executableName: "Worker")
            ],
            paths: [
                100: appExecutable("First"),
                101: appExecutable("Second"),
                200: appExecutable("First", component: "Worker")
            ]
        )
        let clock = StubUptime(value: 1)
        let monitor = makeMonitor(reader: reader, clock: clock)
        let appInventory = inventory(
            app("First", pid: 100),
            app("Second", pid: 101)
        )
        let service = MonitoringService(processMonitor: monitor)

        var sampleResult = await service.sample(request(
            inventory: appInventory,
            processChange: nil
        ))
        var apps = try #require(sampleResult.apps)
        #expect(apps.first { $0.bundleIdentifier == bundleIdentifier("First") }?
            .processIdentifiers == [100, 200])

        let execNotification = ManagedProcessWatcher.notification(
            for: .exec,
            identity: helper
        )
        #expect(execNotification.invalidatedMetadata == [helper])
        #expect(execNotification.processTableChanged)
        let forkNotification = ManagedProcessWatcher.notification(
            for: .fork,
            identity: helper
        )
        #expect(forkNotification.invalidatedMetadata.isEmpty)
        #expect(forkNotification.processTableChanged)
        let exitNotification = ManagedProcessWatcher.notification(
            for: .exit,
            identity: helper
        )
        #expect(exitNotification.invalidatedMetadata == [helper])
        #expect(exitNotification.processTableChanged)
        #expect(!ProcessChangeNotification.audioActivity.processTableChanged)
        #expect(ProcessChangeNotification.audioActivity.audioActivityChanged)
        #expect(!forkNotification.audioActivityChanged)
        #expect(ProcessChangeNotification.coalescing(
            forkNotification,
            execNotification
        ) == execNotification)
        #expect(ProcessChangeNotification.coalescing(
            forkNotification,
            .audioActivity
        ) == ProcessChangeNotification(
            invalidatedMetadata: [],
            processTableChanged: true,
            audioActivityChanged: true
        ))

        reader.paths[200] = appExecutable("Second", component: "Worker")
        clock.value = 2
        sampleResult = await service.sample(request(
            inventory: appInventory,
            processChange: execNotification
        ))
        apps = try #require(sampleResult.apps)
        #expect(apps.first { $0.bundleIdentifier == bundleIdentifier("First") }?
            .processIdentifiers == [100])
        #expect(apps.first { $0.bundleIdentifier == bundleIdentifier("Second") }?
            .processIdentifiers == [101, 200])

        reader.paths[200] = nil
        clock.value = 3
        sampleResult = await service.sample(request(
            inventory: appInventory,
            processChange: exitNotification
        ))
        apps = try #require(sampleResult.apps)
        #expect(apps.first { $0.bundleIdentifier == bundleIdentifier("Second") }?
            .processIdentifiers == [101])
        #expect(reader.pathReads[200] == 3)
        #expect(monitor.cachedMetadataCount == 2)
    }

    @Test("Process-only refreshes reuse the last audio activity snapshot")
    @MainActor
    func processRefreshReusesAudioActivity() async {
        let identity = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [100: snapshot(identity)],
            paths: [100: appExecutable("Example")]
        )
        let audioProbe = StubAudioProcessProbe()
        let monitor = ProcessMonitor(
            processReader: reader,
            currentUserID: 501,
            uptime: { 1 },
            audioProcessIdentifiers: { audioProbe.read() },
            windowSnapshot: { nil }
        )
        let appInventory = inventory(app("Example", pid: 100))
        let service = MonitoringService(processMonitor: monitor)
        let processChange = ManagedProcessWatcher.notification(
            for: .fork,
            identity: identity
        )

        _ = await service.sample(request(
            inventory: appInventory,
            processChange: nil
        ))
        _ = await service.sample(request(
            inventory: appInventory,
            processChange: processChange
        ))
        #expect(audioProbe.readCount == 1)

        _ = await service.sample(request(
            inventory: appInventory,
            processChange: .audioActivity
        ))
        #expect(audioProbe.readCount == 2)
    }

    @Test("Cached system-process samples still refresh audio activity")
    @MainActor
    func cachedSystemProcessSampleRefreshesAudioActivity() async throws {
        let identity = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [100: snapshot(identity)],
            paths: [100: appExecutable("Example")]
        )
        let clock = StubUptime(value: 1)
        let audioProbe = StubAudioProcessProbe()
        let monitor = ProcessMonitor(
            processReader: reader,
            currentUserID: 501,
            uptime: { clock.value },
            audioProcessIdentifiers: { audioProbe.read() },
            windowSnapshot: { nil },
            processTableReader: {
                (
                    entries: [ProcessTableEntry(
                        pid: 100,
                        parentPID: 1,
                        userID: 501,
                        cpuPercent: 0,
                        command: "/Applications/Example.app/Contents/MacOS/Example"
                    )],
                    samplerPID: 999
                )
            }
        )
        let appInventory = inventory(app("Example", pid: 100))

        _ = await monitor.sample(
            inventory: appInventory,
            includingEssentialSystemProcesses: true
        )
        clock.value = 2
        _ = await monitor.sample(
            inventory: appInventory,
            includingEssentialSystemProcesses: true
        )

        audioProbe.processIdentifiers = [100]
        clock.value = 2.1
        let cachedRefresh = try #require(await monitor.sample(
            inventory: appInventory,
            includingEssentialSystemProcesses: true,
            refreshesAudioActivity: true
        ).first)

        #expect(cachedRefresh.isPlayingAudio)
        #expect(audioProbe.readCount == 3)
        #expect(!monitor.didRefreshLastSample)
    }

    private func makeMonitor(
        reader: StubProcessSnapshotReader,
        clock: StubUptime,
        audioPIDs: Set<pid_t> = [],
        networkStates: [ProcessIdentity: ProcessNetworkActivity] = [:],
        windowVisibilitySnapshot: WindowVisibilitySnapshot? = nil
    ) -> ProcessMonitor {
        ProcessMonitor(
            processReader: reader,
            currentUserID: 501,
            uptime: { clock.value },
            audioProcessIdentifiers: { audioPIDs },
            networkActivity: { networkStates[$0] ?? .inactive },
            windowSnapshot: { windowVisibilitySnapshot }
        )
    }

    private func request(
        inventory: ApplicationInventory,
        processChange: ProcessChangeNotification?
    ) -> MonitoringRequest {
        MonitoringRequest(
            generation: 1,
            inventory: inventory,
            samplesSystemCPU: false,
            samplesApplications: true,
            includesEssentialSystemProcesses: false,
            samplesPower: false,
            processChange: processChange
        )
    }

    private func snapshot(
        _ identity: ProcessIdentity,
        parentPID: pid_t = 1,
        executableName: String = "Example",
        cpuNanoseconds: UInt64 = 0,
        residentMemoryBytes: UInt64 = 128 * 1_024 * 1_024
    ) -> ProcessKernelSnapshot {
        ProcessKernelSnapshot(
            identity: identity,
            parentPID: parentPID,
            userID: 501,
            executableName: executableName,
            totalCPUTimeNanoseconds: cpuNanoseconds,
            residentMemoryBytes: residentMemoryBytes
        )
    }

    private func app(_ name: String, pid: pid_t) -> RunningApplicationDescriptor {
        RunningApplicationDescriptor(
            bundleIdentifier: bundleIdentifier(name),
            localizedName: name,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            processIdentifier: pid,
            activationPolicyRawValue: NSApplication.ActivationPolicy.regular.rawValue,
            isHidden: false
        )
    }

    private func inventory(
        _ applications: RunningApplicationDescriptor...
    ) -> ApplicationInventory {
        ApplicationInventory(
            applications: applications,
            frontmostBundleIdentifier: nil,
            ownBundleIdentifier: nil
        )
    }

    private func bundleIdentifier(_ name: String) -> String {
        "example.\(name.lowercased())"
    }

    private func appExecutable(_ name: String, component: String? = nil) -> String {
        let executable = component ?? name
        return "/Applications/\(name).app/Contents/MacOS/\(executable)"
    }
}

private final class StubProcessSnapshotReader: ProcessSnapshotReading {
    var snapshots: [pid_t: ProcessKernelSnapshot]
    var paths: [pid_t: String]
    private(set) var pathReads: [pid_t: Int] = [:]

    init(
        snapshots: [pid_t: ProcessKernelSnapshot],
        paths: [pid_t: String]
    ) {
        self.snapshots = snapshots
        self.paths = paths
    }

    func processIdentifiers() -> [pid_t] {
        snapshots.keys.sorted()
    }

    func snapshot(for pid: pid_t) -> ProcessKernelSnapshot? {
        snapshots[pid]
    }

    func executablePath(for pid: pid_t) -> String? {
        pathReads[pid, default: 0] += 1
        return paths[pid]
    }
}

private final class StubUptime {
    var value: TimeInterval

    init(value: TimeInterval) {
        self.value = value
    }
}

private final class StubAudioProcessProbe {
    private(set) var readCount = 0
    var processIdentifiers: Set<pid_t> = []

    func read() -> Set<pid_t> {
        readCount += 1
        return processIdentifiers
    }
}
