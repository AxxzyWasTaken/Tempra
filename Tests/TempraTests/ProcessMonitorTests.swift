import AppKit
import Darwin
import Foundation
import Testing
@testable import Tempra

@Suite("Process monitor metadata cache")
struct ProcessMonitorTests {
    @Test("Stable metadata is cached while CPU counters remain current")
    func stableMetadataAndCurrentCPU() throws {
        let identity = ProcessIdentity(pid: 100, startTimeMicroseconds: 2_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [100: snapshot(identity, cpuNanoseconds: 1_000_000_000)],
            paths: [100: appExecutable("Example")]
        )
        let clock = StubUptime(value: 10)
        let monitor = makeMonitor(reader: reader, clock: clock)
        let inventory = inventory(app("Example", pid: 100))

        let initial = try #require(monitor.sample(inventory: inventory).first)
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
        let updated = try #require(monitor.sample(inventory: inventory).first)

        #expect(abs(updated.cpuPercent - 50) < 0.000_000_1)
        #expect(updated.residentMemoryBytes == 160 * 1_024 * 1_024)
        #expect(reader.pathReads[100] == 1)
        #expect(monitor.cachedMetadataCount == 1)
    }

    @Test("New processes are cached and exited processes are removed")
    func newAndExitedProcesses() {
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

        _ = monitor.sample(inventory: appInventory)
        #expect(monitor.cachedMetadataCount == 1)

        reader.snapshots[200] = snapshot(helperIdentity, parentPID: 100)
        clock.value = 2
        let withHelper = monitor.sample(inventory: appInventory)
        #expect(withHelper.first?.processIdentifiers == [100, 200])
        #expect(monitor.cachedMetadataCount == 2)
        #expect(reader.pathReads[200] == 1)

        reader.snapshots[200] = snapshot(helperIdentity, parentPID: 1)
        clock.value = 3
        let reparentedHelper = monitor.sample(inventory: appInventory)
        #expect(reparentedHelper.first?.processIdentifiers == [100])
        #expect(reader.pathReads[200] == 1)

        reader.snapshots.removeValue(forKey: 200)
        clock.value = 4
        let withoutHelper = monitor.sample(inventory: appInventory)
        #expect(withoutHelper.first?.processIdentifiers == [100])
        #expect(monitor.cachedMetadataCount == 1)

        reader.snapshots.removeAll()
        clock.value = 5
        #expect(monitor.sample(inventory: appInventory).isEmpty)
        #expect(monitor.cachedMetadataCount == 0)
    }

    @Test("PID reuse replaces metadata and resets the CPU baseline")
    func pidReuse() throws {
        let firstIdentity = ProcessIdentity(pid: 100, startTimeMicroseconds: 1_000_000)
        let replacementIdentity = ProcessIdentity(pid: 100, startTimeMicroseconds: 9_000_000)
        let reader = StubProcessSnapshotReader(
            snapshots: [100: snapshot(firstIdentity, cpuNanoseconds: 8_000_000_000)],
            paths: [100: appExecutable("Example")]
        )
        let clock = StubUptime(value: 1)
        let monitor = makeMonitor(reader: reader, clock: clock)
        let appInventory = inventory(app("Example", pid: 100))

        _ = monitor.sample(inventory: appInventory)
        reader.snapshots[100] = snapshot(replacementIdentity, cpuNanoseconds: 100_000_000)
        reader.paths[100] = "/Applications/Example.app/Contents/MacOS/Replacement"
        clock.value = 2

        let replacement = try #require(monitor.sample(inventory: appInventory).first)
        #expect(replacement.processIdentities == [replacementIdentity])
        #expect(replacement.launchedAt?.timeIntervalSince1970 == 9)
        #expect(replacement.cpuPercent == 0)
        #expect(reader.pathReads[100] == 2)
        #expect(monitor.cachedMetadataCount == 1)
    }

    @Test("Forked helpers join every instance and retain audio and launch metadata")
    func forkedHelperAssignment() throws {
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
        let monitor = makeMonitor(reader: reader, clock: clock, audioPIDs: [200])
        let appInventory = inventory(
            app("Example", pid: 100),
            app("Example", pid: 101)
        )

        let beforeFork = try #require(monitor.sample(inventory: appInventory).first)
        #expect(beforeFork.processIdentifiers == [100, 101])

        reader.snapshots[200] = snapshot(helper, parentPID: 100)
        reader.snapshots[201] = snapshot(helperChild, parentPID: 200)
        clock.value = 2
        let afterFork = try #require(monitor.sample(inventory: appInventory).first)

        #expect(afterFork.processIdentifiers == [100, 101, 200, 201])
        #expect(Set(afterFork.processIdentities) == [firstMain, secondMain, helper, helperChild])
        #expect(afterFork.residentMemoryBytes == 512 * 1_024 * 1_024)
        #expect(afterFork.launchedAt?.timeIntervalSince1970 == 2)
        #expect(afterFork.isPlayingAudio)
    }

    @Test("User-owned system extensions remain controllable services")
    func userOwnedSystemExtension() throws {
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

        let results = monitor.sample(
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

    @Test("Window visibility is applied to each app from one snapshot")
    func batchedWindowVisibilityIsAppliedToApps() throws {
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

        let apps = monitor.sample(inventory: inventory(
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
        #expect(ProcessChangeNotification.coalescing(
            forkNotification,
            execNotification
        ) == execNotification)

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

    private func makeMonitor(
        reader: StubProcessSnapshotReader,
        clock: StubUptime,
        audioPIDs: Set<pid_t> = [],
        windowVisibilitySnapshot: WindowVisibilitySnapshot? = nil
    ) -> ProcessMonitor {
        ProcessMonitor(
            processReader: reader,
            currentUserID: 501,
            uptime: { clock.value },
            audioProcessIdentifiers: { audioPIDs },
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
