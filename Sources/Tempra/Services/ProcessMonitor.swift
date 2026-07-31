import AppKit
import Darwin
import Foundation

struct ProcessTableEntry: Equatable {
    let pid: pid_t
    let parentPID: pid_t
    let userID: uid_t
    let cpuPercent: Double
    let command: String

    static func parse(_ output: String) -> [ProcessTableEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(
                maxSplits: 4,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 5,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1]),
                  let userID = UInt32(fields[2]),
                  let cpuPercent = Double(fields[3]) else {
                return nil
            }
            return ProcessTableEntry(
                pid: pid,
                parentPID: parentPID,
                userID: userID,
                cpuPercent: max(0, cpuPercent),
                command: String(fields[4])
            )
        }
    }
}

enum BackgroundProcessPolicy {
    static let systemApplicationBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.WindowManager",
        "com.apple.loginwindow"
    ]
    static let identifierPrefix = "tempra.background:"

    static func shouldIncludeApplication(
        bundleIdentifier: String,
        activationPolicy: NSApplication.ActivationPolicy,
        includesBackgroundProcesses: Bool
    ) -> Bool {
        if includesBackgroundProcesses {
            return true
        }
        if systemApplicationBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }
        return activationPolicy != .prohibited
    }

    static func isMonitorOnlyApplication(
        bundleIdentifier: String,
        userID: uid_t,
        currentUserID: uid_t
    ) -> Bool {
        systemApplicationBundleIdentifiers.contains(bundleIdentifier)
            || userID != currentUserID
    }

    static func isServiceApplication(
        activationPolicy: NSApplication.ActivationPolicy
    ) -> Bool {
        activationPolicy != .regular
    }

    static func identifier(command: String, pid: pid_t) -> String {
        let identity = command.isEmpty ? "pid:\(pid)" : "command:\(command)"
        return identifierPrefix + identity
    }

    static func displayName(command: String, pid: pid_t) -> String {
        guard !command.isEmpty else { return "Process \(pid)" }
        if command.contains("/") {
            let name = URL(fileURLWithPath: command).lastPathComponent
            if !name.isEmpty { return name }
        }
        return command
    }

    static func isMonitorOnlyIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
            || systemApplicationBundleIdentifiers.contains(identifier)
    }
}

struct RunningApplicationDescriptor: Sendable {
    let bundleIdentifier: String
    let localizedName: String?
    let bundleURL: URL
    let processIdentifier: pid_t
    let activationPolicyRawValue: Int
    let isHidden: Bool

    var activationPolicy: NSApplication.ActivationPolicy {
        NSApplication.ActivationPolicy(rawValue: activationPolicyRawValue) ?? .prohibited
    }
}

struct ApplicationInventory: Sendable {
    let applications: [RunningApplicationDescriptor]
    let frontmostBundleIdentifier: String?
    let ownBundleIdentifier: String?

    @MainActor
    static func capture() -> ApplicationInventory {
        ApplicationInventory(
            applications: NSWorkspace.shared.runningApplications.compactMap { application in
                guard let bundleIdentifier = application.bundleIdentifier,
                      let bundleURL = application.bundleURL else {
                    return nil
                }
                return RunningApplicationDescriptor(
                    bundleIdentifier: bundleIdentifier,
                    localizedName: application.localizedName,
                    bundleURL: bundleURL,
                    processIdentifier: application.processIdentifier,
                    activationPolicyRawValue: application.activationPolicy.rawValue,
                    isHidden: application.isHidden
                )
            },
            frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            ownBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }
}

enum ForegroundApplicationPolicy {
    static func isMenuBarOverlay(
        _ application: RunningApplicationDescriptor?,
        windowSnapshot: WindowVisibilitySnapshot?
    ) -> Bool {
        guard let application, application.activationPolicy != .regular else {
            return false
        }
        return windowSnapshot?.hasNormalWindow(
            for: [application.processIdentifier]
        ) != true
    }
}

struct ForegroundApplicationTracker {
    private var lastNonMenuBarIdentifier: String?

    mutating func protectedIdentifier(
        frontmostIdentifier: String?,
        isMenuBarOverlay: Bool
    ) -> String? {
        if isMenuBarOverlay {
            return lastNonMenuBarIdentifier
        }
        lastNonMenuBarIdentifier = frontmostIdentifier
        return nil
    }
}

struct ProcessKernelSnapshot: Equatable, Sendable {
    let identity: ProcessIdentity
    let parentPID: pid_t
    let userID: uid_t
    let executableName: String
    let totalCPUTimeNanoseconds: UInt64
    let residentMemoryBytes: UInt64
}

protocol ProcessSnapshotReading {
    func processIdentifiers() -> [pid_t]
    func snapshot(for pid: pid_t) -> ProcessKernelSnapshot?
    func executablePath(for pid: pid_t) -> String?
}

struct LiveProcessSnapshotReader: ProcessSnapshotReading {
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        _ = mach_timebase_info(&info)
        return info
    }()

    func processIdentifiers() -> [pid_t] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(count))
        let (byteCount, byteCountOverflow) = pids.count.multipliedReportingOverflow(
            by: MemoryLayout<pid_t>.size
        )
        guard !byteCountOverflow, byteCount <= Int(Int32.max) else { return [] }
        count = proc_listallpids(&pids, Int32(byteCount))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    func snapshot(for pid: pid_t) -> ProcessKernelSnapshot? {
        var info = proc_taskallinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        let readSize = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, expectedSize)
        guard readSize == expectedSize else { return nil }

        let (startSeconds, startSecondsOverflow) = UInt64(info.pbsd.pbi_start_tvsec)
            .multipliedReportingOverflow(by: 1_000_000)
        let (startTimeMicroseconds, startTimeOverflow) = startSeconds
            .addingReportingOverflow(UInt64(info.pbsd.pbi_start_tvusec))
        let (totalTicks, totalTicksOverflow) = info.ptinfo.pti_total_user
            .addingReportingOverflow(info.ptinfo.pti_total_system)
        guard !startSecondsOverflow,
              !startTimeOverflow,
              !totalTicksOverflow,
              let totalCPUTimeNanoseconds = Self.nanoseconds(fromMachTicks: totalTicks) else {
            return nil
        }
        var nameBytes = info.pbsd.pbi_name
        let executableName = withUnsafeBytes(of: &nameBytes) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessKernelSnapshot(
            identity: ProcessIdentity(
                pid: pid,
                startTimeMicroseconds: startTimeMicroseconds
            ),
            parentPID: pid_t(info.pbsd.pbi_ppid),
            userID: info.pbsd.pbi_uid,
            executableName: executableName,
            totalCPUTimeNanoseconds: totalCPUTimeNanoseconds,
            residentMemoryBytes: info.ptinfo.pti_resident_size
        )
    }

    func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64? {
        let numerator = UInt64(machTimebase.numer)
        let denominator = UInt64(machTimebase.denom)
        guard denominator > 0 else { return ticks }

        let whole = ticks / denominator
        let remainder = ticks % denominator
        let (wholeNanoseconds, wholeOverflow) = whole.multipliedReportingOverflow(by: numerator)
        let (remainderProduct, remainderOverflow) = remainder.multipliedReportingOverflow(
            by: numerator
        )
        let (nanoseconds, totalOverflow) = wholeNanoseconds.addingReportingOverflow(
            remainderProduct / denominator
        )
        guard !wholeOverflow, !remainderOverflow, !totalOverflow else { return nil }
        return nanoseconds
    }
}

private struct ProcessMetadata {
    let identity: ProcessIdentity
    let parentPID: pid_t
    let userID: uid_t
    let executableName: String
    let name: String
    let path: String

    func matchesExecutable(_ snapshot: ProcessKernelSnapshot) -> Bool {
        userID == snapshot.userID && executableName == snapshot.executableName
    }

    func updatingParent(to parentPID: pid_t) -> ProcessMetadata {
        ProcessMetadata(
            identity: identity,
            parentPID: parentPID,
            userID: userID,
            executableName: executableName,
            name: name,
            path: path
        )
    }
}

private struct ProcessMetadataCache {
    private var entries: [ProcessIdentity: ProcessMetadata] = [:]

    var count: Int { entries.count }

    mutating func retain(_ identities: Set<ProcessIdentity>) {
        entries = entries.filter { identities.contains($0.key) }
    }

    mutating func invalidate(_ identities: Set<ProcessIdentity>) {
        for identity in identities {
            entries.removeValue(forKey: identity)
        }
    }

    mutating func metadata(
        for snapshot: ProcessKernelSnapshot,
        pathReader: (pid_t) -> String?
    ) -> ProcessMetadata {
        if let cached = entries[snapshot.identity], cached.matchesExecutable(snapshot) {
            guard cached.parentPID != snapshot.parentPID else { return cached }
            let updated = cached.updatingParent(to: snapshot.parentPID)
            entries[snapshot.identity] = updated
            return updated
        }

        entries.removeValue(forKey: snapshot.identity)
        guard let path = pathReader(snapshot.identity.pid) else {
            return ProcessMetadata(
                identity: snapshot.identity,
                parentPID: snapshot.parentPID,
                userID: snapshot.userID,
                executableName: snapshot.executableName,
                name: BackgroundProcessPolicy.displayName(
                    command: snapshot.executableName,
                    pid: snapshot.identity.pid
                ),
                path: ""
            )
        }

        let metadata = ProcessMetadata(
            identity: snapshot.identity,
            parentPID: snapshot.parentPID,
            userID: snapshot.userID,
            executableName: snapshot.executableName,
            name: BackgroundProcessPolicy.displayName(
                command: path,
                pid: snapshot.identity.pid
            ),
            path: path
        )
        entries[snapshot.identity] = metadata
        return metadata
    }
}

struct ProcessAssignmentResolver {
    struct Process: Equatable {
        let pid: pid_t
        let parentPID: pid_t
        let path: String
    }

    struct Bundle: Equatable {
        let identifier: String
        let path: String
        let mainPIDs: Set<pid_t>
    }

    static func assignments(
        processes: [Process],
        bundles: [Bundle]
    ) -> [String: [pid_t]] {
        var mainPIDMap: [pid_t: String] = [:]
        for bundle in bundles {
            for pid in bundle.mainPIDs {
                mainPIDMap[pid] = bundle.identifier
            }
        }

        let bundleIdentifiers = Set(bundles.map(\.identifier))
        let pathIndex = BundlePathPrefixIndex(bundles: bundles)
        var ancestryResolver = MainAncestryResolver(
            processes: processes,
            mainPIDMap: mainPIDMap
        )
        var result: [String: [pid_t]] = [:]

        for process in processes {
            var identifier = mainPIDMap[process.pid]
            if identifier == nil, !process.path.isEmpty {
                identifier = pathIndex.longestPrefixIdentifier(for: process.path)
            }
            if identifier == nil {
                identifier = ancestryResolver.identifier(forParent: process.parentPID)
            }
            if let identifier, bundleIdentifiers.contains(identifier) {
                result[identifier, default: []].append(process.pid)
            }
        }
        return result
    }

    private struct BundlePathPrefixIndex {
        private struct Node {
            var children: [Character: Int] = [:]
            var identifier: String?
        }

        private var nodes: [Node] = [Node()]

        init(bundles: [Bundle]) {
            for bundle in bundles {
                var nodeIndex = 0
                for character in bundle.path + "/" {
                    if let childIndex = nodes[nodeIndex].children[character] {
                        nodeIndex = childIndex
                    } else {
                        let childIndex = nodes.count
                        nodes.append(Node())
                        nodes[nodeIndex].children[character] = childIndex
                        nodeIndex = childIndex
                    }
                }
                if nodes[nodeIndex].identifier == nil {
                    nodes[nodeIndex].identifier = bundle.identifier
                }
            }
        }

        func longestPrefixIdentifier(for path: String) -> String? {
            var nodeIndex = 0
            var identifier: String?
            for character in path {
                guard let childIndex = nodes[nodeIndex].children[character] else {
                    break
                }
                nodeIndex = childIndex
                if let matchedIdentifier = nodes[nodeIndex].identifier {
                    identifier = matchedIdentifier
                }
            }
            return identifier
        }
    }

    private struct MainAncestryResolver {
        private enum Resolution {
            case assigned(String)
            case unassigned

            var identifier: String? {
                switch self {
                case .assigned(let identifier): identifier
                case .unassigned: nil
                }
            }
        }

        private let parentByPID: [pid_t: pid_t]
        private let mainPIDMap: [pid_t: String]
        private var cachedResolutions: [pid_t: Resolution] = [:]

        init(processes: [Process], mainPIDMap: [pid_t: String]) {
            var parents: [pid_t: pid_t] = [:]
            for process in processes {
                parents[process.pid] = process.parentPID
            }
            parentByPID = parents
            self.mainPIDMap = mainPIDMap
        }

        mutating func identifier(forParent parentPID: pid_t) -> String? {
            var currentPID = parentPID
            var path: [pid_t] = []
            var visited: Set<pid_t> = []
            var resolution = Resolution.unassigned

            while currentPID > 1 {
                if let identifier = mainPIDMap[currentPID] {
                    resolution = .assigned(identifier)
                    break
                }
                if let cached = cachedResolutions[currentPID] {
                    resolution = cached
                    break
                }
                guard visited.insert(currentPID).inserted else { break }
                path.append(currentPID)
                guard let parentPID = parentByPID[currentPID] else { break }
                currentPID = parentPID
            }

            for pid in path {
                cachedResolutions[pid] = resolution
            }
            return resolution.identifier
        }
    }
}

final class ProcessMonitor {
    private(set) var didRefreshLastSample = true

    private struct CPUCounter {
        let totalNanoseconds: UInt64
    }

    private struct RawProcess {
        let pid: pid_t
        let identity: ProcessIdentity?
        let parentPID: pid_t
        let userID: uid_t
        let name: String
        let path: String
        let counter: CPUCounter?
        let reportedCPUPercent: Double?
        let residentMemoryBytes: UInt64?
    }

    private struct RunningBundle {
        let identifier: String
        let name: String
        let url: URL
        var mainPIDs: Set<pid_t>
        var isHidden: Bool
        var isService: Bool
        var isSystemProcess: Bool
    }

    private struct BackgroundProcessGroup {
        let identifier: String
        let name: String
        let url: URL?
        var pids: [pid_t]
        var cpuPercent: Double
        var residentMemoryBytes: UInt64?
    }

    private var previousCounters: [ProcessIdentity: CPUCounter] = [:]
    private var previousSampleTime: TimeInterval
    private var metadataCache = ProcessMetadataCache()
    private var cachedProcessTableEntries: [ProcessTableEntry] = []
    private var processTableRefreshTime: TimeInterval = 0
    private let processTableRefreshInterval: TimeInterval = 3
    private var cachedBackgroundSample: [ManagedApp] = []
    private var backgroundSampleTime: TimeInterval = 0
    private var lastIncludedBackgroundProcesses = false
    private var foregroundApplicationTracker = ForegroundApplicationTracker()
    private let processReader: any ProcessSnapshotReading
    private let currentUserID: uid_t
    private let uptime: () -> TimeInterval
    private let audioProcessIdentifiers: () -> Set<pid_t>
    private let windowSnapshot: () -> WindowVisibilitySnapshot?

    var cachedMetadataCount: Int { metadataCache.count }

    init(
        processReader: any ProcessSnapshotReading = LiveProcessSnapshotReader(),
        currentUserID: uid_t = getuid(),
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        audioProcessIdentifiers: @escaping () -> Set<pid_t> = {
            AudioOutputProbe.playingProcessIdentifiers()
        },
        windowSnapshot: @escaping () -> WindowVisibilitySnapshot? = {
            WindowVisibilitySnapshot.capture()
        }
    ) {
        self.processReader = processReader
        self.currentUserID = currentUserID
        self.uptime = uptime
        self.audioProcessIdentifiers = audioProcessIdentifiers
        self.windowSnapshot = windowSnapshot
        previousSampleTime = uptime()
    }

    @MainActor
    func sample(includingEssentialSystemProcesses: Bool = false) -> [ManagedApp] {
        sample(
            inventory: .capture(),
            includingEssentialSystemProcesses: includingEssentialSystemProcesses
        )
    }

    func sample(
        inventory: ApplicationInventory,
        includingEssentialSystemProcesses: Bool = false
    ) -> [ManagedApp] {
        let now = uptime()
        let inclusionChanged = includingEssentialSystemProcesses != lastIncludedBackgroundProcesses
        lastIncludedBackgroundProcesses = includingEssentialSystemProcesses
        if includingEssentialSystemProcesses,
           !inclusionChanged,
           !cachedBackgroundSample.isEmpty,
           now - backgroundSampleTime < processTableRefreshInterval {
            didRefreshLastSample = false
            cachedBackgroundSample = applyingWindowState(
                to: cachedBackgroundSample,
                inventory: inventory
            )
            return cachedBackgroundSample
        }
        didRefreshLastSample = true
        let elapsed = max(now - previousSampleTime, 0.001)
        let rawProcesses = readProcesses(
            includingBackgroundProcesses: includingEssentialSystemProcesses
        )
        let rawByPID = Dictionary(uniqueKeysWithValues: rawProcesses.map { ($0.pid, $0) })
        let bundles = runningBundles(
            rawByPID: rawByPID,
            inventory: inventory,
            includesEssentialSystemProcesses: includingEssentialSystemProcesses
        )
        let assignments = assignProcesses(rawProcesses, to: bundles)
        let playingAudioProcessIdentifiers = audioProcessIdentifiers()

        var currentCounters: [ProcessIdentity: CPUCounter] = [:]
        var cpuByPID: [pid_t: Double] = [:]

        for process in rawProcesses {
            guard let identity = process.identity, let counter = process.counter else {
                cpuByPID[process.pid] = process.reportedCPUPercent ?? 0
                continue
            }
            currentCounters[identity] = counter

            guard let previous = previousCounters[identity],
                  counter.totalNanoseconds >= previous.totalNanoseconds else {
                cpuByPID[process.pid] = 0
                continue
            }

            let delta = counter.totalNanoseconds - previous.totalNanoseconds
            cpuByPID[process.pid] = (Double(delta) / (elapsed * 1_000_000_000)) * 100
        }

        previousCounters = currentCounters
        previousSampleTime = now

        let bundledApps = bundles.values.compactMap { bundle -> ManagedApp? in
            let pids = assignments[bundle.identifier, default: []].sorted()
            guard !pids.isEmpty else { return nil }

            let cpu = pids.reduce(0) { $0 + cpuByPID[$1, default: 0] }
            let isPlayingAudio = bundle.isSystemProcess
                ? false
                : pids.contains(where: playingAudioProcessIdentifiers.contains)

            return ManagedApp(
                bundleIdentifier: bundle.identifier,
                name: bundle.name,
                bundleURL: bundle.url,
                processIdentifiers: pids,
                processIdentities: pids.compactMap { rawByPID[$0]?.identity },
                launchedAt: bundle.mainPIDs
                    .compactMap { rawByPID[$0]?.identity }
                    .map {
                        Date(
                            timeIntervalSince1970: Double($0.startTimeMicroseconds) / 1_000_000
                        )
                    }
                    .min(),
                cpuPercent: max(0, cpu),
                residentMemoryBytes: residentMemoryBytes(
                    for: pids,
                    rawByPID: rawByPID
                ),
                isFrontmost: bundle.identifier == inventory.frontmostBundleIdentifier,
                isHidden: bundle.isHidden,
                isPlayingAudio: isPlayingAudio,
                isService: bundle.isService,
                isSystemProcess: bundle.isSystemProcess,
                status: .normal
            )
        }

        let backgroundApps: [ManagedApp]
        if includingEssentialSystemProcesses {
            let assignedPIDs = Set(assignments.values.flatMap { $0 })
            backgroundApps = makeBackgroundProcessGroups(
                from: rawProcesses,
                excluding: assignedPIDs,
                cpuByPID: cpuByPID
            )
        } else {
            backgroundApps = []
        }

        let result = applyingWindowState(
            to: bundledApps + backgroundApps,
            inventory: inventory
        )
        if includingEssentialSystemProcesses {
            cachedBackgroundSample = result
            backgroundSampleTime = now
        }
        return result
    }

    private func applyingWindowState(
        to apps: [ManagedApp],
        inventory: ApplicationInventory
    ) -> [ManagedApp] {
        let windowSnapshot = windowSnapshot()
        let applicationsByIdentifier = Dictionary(
            grouping: inventory.applications,
            by: \.bundleIdentifier
        )
        let frontmostApplication = inventory.applications.first {
            $0.bundleIdentifier == inventory.frontmostBundleIdentifier
        }
        let frontmostIsMenuBarOverlay = ForegroundApplicationPolicy.isMenuBarOverlay(
            frontmostApplication,
            windowSnapshot: windowSnapshot
        )
        let protectedIdentifier = foregroundApplicationTracker.protectedIdentifier(
            frontmostIdentifier: inventory.frontmostBundleIdentifier,
            isMenuBarOverlay: frontmostIsMenuBarOverlay
        )

        var updatedApps = apps.map { app in
            guard !app.isSystemProcess else { return app }
            var updated = app
            if let applications = applicationsByIdentifier[app.bundleIdentifier] {
                updated.isHidden = applications.allSatisfy(\.isHidden)
            }
            updated.isFrontmost = app.bundleIdentifier == inventory.frontmostBundleIdentifier
            updated.isProtectedByMenuBarOverlay = frontmostIsMenuBarOverlay
                && app.bundleIdentifier == protectedIdentifier
            return updated
        }
        let requestIndices = updatedApps.indices.filter { !updatedApps[$0].isSystemProcess }
        let requests = requestIndices.map { index in
            WindowVisibilitySnapshot.Request(
                processIdentifiers: Set(updatedApps[index].processIdentifiers),
                isHidden: updatedApps[index].isHidden
            )
        }
        let visibilities = windowSnapshot?.visibilities(for: requests)
        for (requestOffset, appIndex) in requestIndices.enumerated() {
            updatedApps[appIndex].windowVisibility = visibilities?[requestOffset]
                ?? (updatedApps[appIndex].isHidden ? .hiddenOrMinimized : .unknown)
        }
        return updatedApps
    }

    func resetSamplingBaseline() {
        previousCounters.removeAll()
        previousSampleTime = uptime()
        didRefreshLastSample = true
    }

    func handleProcessChange(_ notification: ProcessChangeNotification) {
        metadataCache.invalidate(notification.invalidatedMetadata)
        cachedBackgroundSample.removeAll()
        backgroundSampleTime = 0
        if notification.processTableChanged {
            cachedProcessTableEntries.removeAll()
            processTableRefreshTime = 0
        }
    }

    private func readProcesses(includingBackgroundProcesses: Bool) -> [RawProcess] {
        guard includingBackgroundProcesses else {
            return readAccessibleProcesses()
        }

        let accessibleProcesses = readAccessibleProcesses()
        let accessibleByPID = Dictionary(
            uniqueKeysWithValues: accessibleProcesses.map { ($0.pid, $0) }
        )

        let now = uptime()
        if cachedProcessTableEntries.isEmpty
            || now - processTableRefreshTime >= processTableRefreshInterval {
            guard let processTable = readProcessTable() else {
                cachedProcessTableEntries.removeAll()
                processTableRefreshTime = now
                return accessibleProcesses
            }
            cachedProcessTableEntries = processTable.entries.filter {
                $0.pid != processTable.samplerPID
            }
            processTableRefreshTime = now
        }

        return cachedProcessTableEntries.map { entry in
            if let accessible = accessibleByPID[entry.pid] {
                return accessible
            }
            return RawProcess(
                pid: entry.pid,
                identity: nil,
                parentPID: entry.parentPID,
                userID: entry.userID,
                name: BackgroundProcessPolicy.displayName(
                    command: entry.command,
                    pid: entry.pid
                ),
                path: entry.command,
                counter: nil,
                reportedCPUPercent: entry.cpuPercent,
                residentMemoryBytes: nil
            )
        }
    }

    private func readAccessibleProcesses() -> [RawProcess] {
        let snapshots = processReader.processIdentifiers().compactMap {
            pid -> ProcessKernelSnapshot? in
            guard pid > 0,
                  let snapshot = processReader.snapshot(for: pid),
                  snapshot.userID == currentUserID else { return nil }
            return snapshot
        }
        metadataCache.retain(Set(snapshots.map(\.identity)))

        return snapshots.map { snapshot in
            let metadata = metadataCache.metadata(
                for: snapshot,
                pathReader: processReader.executablePath
            )
            return RawProcess(
                pid: snapshot.identity.pid,
                identity: snapshot.identity,
                parentPID: metadata.parentPID,
                userID: metadata.userID,
                name: metadata.name,
                path: metadata.path,
                counter: CPUCounter(
                    totalNanoseconds: snapshot.totalCPUTimeNanoseconds
                ),
                reportedCPUPercent: nil,
                residentMemoryBytes: snapshot.residentMemoryBytes
            )
        }
    }

    private func readProcessTable() -> (entries: [ProcessTableEntry], samplerPID: pid_t)? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,uid=,pcpu=,comm="]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let samplerPID = process.processIdentifier
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (ProcessTableEntry.parse(output), samplerPID)
    }

    private func runningBundles(
        rawByPID: [pid_t: RawProcess],
        inventory: ApplicationInventory,
        includesEssentialSystemProcesses: Bool
    ) -> [String: RunningBundle] {
        var result: [String: RunningBundle] = [:]

        for application in inventory.applications {
            let identifier = application.bundleIdentifier
            guard identifier != inventory.ownBundleIdentifier,
                  BackgroundProcessPolicy.shouldIncludeApplication(
                    bundleIdentifier: identifier,
                    activationPolicy: application.activationPolicy,
                    includesBackgroundProcesses: includesEssentialSystemProcesses
                  ),
                  !application.bundleURL.path.isEmpty,
                  let raw = rawByPID[application.processIdentifier],
                  includesEssentialSystemProcesses || raw.userID == currentUserID else {
                continue
            }

            let name = application.localizedName
                ?? application.bundleURL.deletingPathExtension().lastPathComponent

            let isSystemProcess = BackgroundProcessPolicy.isMonitorOnlyApplication(
                bundleIdentifier: identifier,
                userID: raw.userID,
                currentUserID: currentUserID
            )
            let isService = BackgroundProcessPolicy.isServiceApplication(
                activationPolicy: application.activationPolicy
            )

            if var existing = result[identifier] {
                existing.mainPIDs.insert(application.processIdentifier)
                existing.isHidden = existing.isHidden && application.isHidden
                existing.isService = existing.isService || isService
                existing.isSystemProcess = existing.isSystemProcess || isSystemProcess
                result[identifier] = existing
            } else {
                result[identifier] = RunningBundle(
                    identifier: identifier,
                    name: name,
                    url: application.bundleURL,
                    mainPIDs: [application.processIdentifier],
                    isHidden: application.isHidden,
                    isService: isService,
                    isSystemProcess: isSystemProcess
                )
            }
        }

        return result
    }

    private func makeBackgroundProcessGroups(
        from processes: [RawProcess],
        excluding assignedPIDs: Set<pid_t>,
        cpuByPID: [pid_t: Double]
    ) -> [ManagedApp] {
        var groups: [String: BackgroundProcessGroup] = [:]
        let ownPID = getpid()

        for process in processes where process.pid != ownPID && !assignedPIDs.contains(process.pid) {
            let identifier = BackgroundProcessPolicy.identifier(
                command: process.path,
                pid: process.pid
            )
            if var group = groups[identifier] {
                group.pids.append(process.pid)
                group.cpuPercent += cpuByPID[process.pid, default: 0]
                group.residentMemoryBytes = Self.addingResidentMemory(
                    group.residentMemoryBytes,
                    process.residentMemoryBytes
                )
                groups[identifier] = group
            } else {
                let url = process.path.hasPrefix("/")
                    ? URL(fileURLWithPath: process.path)
                    : nil
                groups[identifier] = BackgroundProcessGroup(
                    identifier: identifier,
                    name: process.name,
                    url: url,
                    pids: [process.pid],
                    cpuPercent: cpuByPID[process.pid, default: 0],
                    residentMemoryBytes: process.residentMemoryBytes
                )
            }
        }

        return groups.values.map { group in
            ManagedApp(
                bundleIdentifier: group.identifier,
                name: group.name,
                bundleURL: group.url,
                processIdentifiers: group.pids.sorted(),
                cpuPercent: max(0, group.cpuPercent),
                residentMemoryBytes: group.residentMemoryBytes,
                isFrontmost: false,
                isHidden: true,
                isPlayingAudio: false,
                isService: true,
                isSystemProcess: true,
                status: .normal
            )
        }
    }

    private func residentMemoryBytes(
        for processIdentifiers: [pid_t],
        rawByPID: [pid_t: RawProcess]
    ) -> UInt64? {
        var total: UInt64 = 0
        for processIdentifier in processIdentifiers {
            guard let value = rawByPID[processIdentifier]?.residentMemoryBytes else {
                return nil
            }
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    private static func addingResidentMemory(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
        guard let lhs, let rhs else { return nil }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }

    private func assignProcesses(
        _ processes: [RawProcess],
        to bundles: [String: RunningBundle]
    ) -> [String: [pid_t]] {
        ProcessAssignmentResolver.assignments(
            processes: processes.map {
                ProcessAssignmentResolver.Process(
                    pid: $0.pid,
                    parentPID: $0.parentPID,
                    path: $0.path
                )
            },
            bundles: bundles.values.map {
                ProcessAssignmentResolver.Bundle(
                    identifier: $0.identifier,
                    path: $0.url.path,
                    mainPIDs: $0.mainPIDs
                )
            }
        )
    }

}
