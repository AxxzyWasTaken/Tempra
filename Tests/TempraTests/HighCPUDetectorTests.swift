import Foundation
import Testing
@testable import Tempra

@Suite("Sustained high CPU notifications")
struct HighCPUDetectorTests {
    private let start = Date(timeIntervalSince1970: 10_000)

    @Test("A below-threshold sample breaks the contiguous streak")
    func contiguousStreak() throws {
        var detector = HighCPUDetector()
        let preferences = alertPreferences()

        for offset in [0.0, 10, 20] {
            let result = evaluate(
                &detector,
                cpuPercent: 120,
                at: offset,
                preferences: preferences
            )
            #expect(result.notificationCandidates.isEmpty)
        }
        _ = evaluate(
            &detector,
            cpuPercent: 40,
            at: 25,
            preferences: preferences
        )
        for offset in [35.0, 45, 55, 65] {
            let result = evaluate(
                &detector,
                cpuPercent: 120,
                at: offset,
                preferences: preferences
            )
            #expect(result.notificationCandidates.isEmpty)
        }

        let result = evaluate(
            &detector,
            cpuPercent: 120,
            at: 66,
            preferences: preferences
        )
        let alert = try #require(result.notificationCandidates.first)
        #expect(alert.bundleIdentifier == "example.hog")
        #expect(alert.threshold == 95)
    }

    @Test("A missing sampling interval does not count as sustained CPU")
    func samplingGapBreaksStreak() {
        var detector = HighCPUDetector()
        let preferences = alertPreferences()

        _ = evaluate(
            &detector,
            cpuPercent: 120,
            at: 0,
            preferences: preferences
        )
        _ = evaluate(
            &detector,
            cpuPercent: 120,
            at: 20,
            preferences: preferences
        )
        for offset in [30.0, 40, 50] {
            let result = evaluate(
                &detector,
                cpuPercent: 120,
                at: offset,
                preferences: preferences
            )
            #expect(result.notificationCandidates.isEmpty)
        }
        let result = evaluate(
            &detector,
            cpuPercent: 120,
            at: 51,
            preferences: preferences
        )
        #expect(result.notificationCandidates.count == 1)
    }

    @Test("Foreground and launch grace periods delay notification")
    func activityAndLaunchGates() {
        var foregroundDetector = HighCPUDetector()
        let preferences = alertPreferences()

        for offset in stride(from: 0.0, through: 100, by: 10) {
            let result = evaluate(
                &foregroundDetector,
                cpuPercent: 120,
                at: offset,
                preferences: preferences,
                isFrontmost: true
            )
            #expect(result.notificationCandidates.isEmpty)
        }
        for offset in [110.0, 120, 130, 140, 150] {
            let result = evaluate(
                &foregroundDetector,
                cpuPercent: 120,
                at: offset,
                preferences: preferences
            )
            #expect(result.notificationCandidates.isEmpty)
        }
        #expect(evaluate(
            &foregroundDetector,
            cpuPercent: 120,
            at: 156,
            preferences: preferences
        ).notificationCandidates.count == 1)

        var launchDetector = HighCPUDetector()
        for offset in stride(from: 0.0, through: 90, by: 10) {
            let result = evaluate(
                &launchDetector,
                cpuPercent: 120,
                at: offset,
                preferences: preferences,
                launchedAt: start
            )
            #expect(result.notificationCandidates.isEmpty)
        }
        #expect(evaluate(
            &launchDetector,
            cpuPercent: 120,
            at: 91,
            preferences: preferences,
            launchedAt: start
        ).notificationCandidates.count == 1)
    }

    @Test("Managed, helper, suspended, and uncontrollable apps are not candidates")
    func candidateGates() {
        let preferences = alertPreferences()
        let scenarios: [(ManagedApp, Set<String>, Set<String>, Bool, Bool)] = [
            (app(cpuPercent: 120, isFrontmost: true), [], [], true, false),
            (app(cpuPercent: 120), ["example.hog"], [], true, false),
            (app(cpuPercent: 120, isNestedHelper: true), [], [], true, false),
            (app(cpuPercent: 120, isBackgroundProcess: true), [], [], true, false),
            (app(cpuPercent: 120, isCurrentApplication: true), [], [], true, false),
            (app(cpuPercent: 120), [], ["example.hog"], true, false),
            (app(cpuPercent: 120), [], [], false, false),
            (
                app(cpuPercent: 120, requiresPrivilegedControl: true),
                [],
                [],
                true,
                false
            )
        ]

        for (candidate, managed, suspended, managementActive, canControlPrivileged) in scenarios {
            var detector = HighCPUDetector()
            var latest = HighCPUDetectionResult(
                attentionIdentifiers: [],
                notificationCandidates: [],
                sustainedProcessIdentities: []
            )
            for offset in stride(from: 0.0, through: 100, by: 10) {
                latest = detector.evaluate(
                    apps: [candidate],
                    preferences: preferences,
                    managedIdentifiers: managed,
                    suspendedIdentifiers: suspended,
                    isManagementActive: managementActive,
                    canControlPrivilegedProcesses: canControlPrivileged,
                    now: start.addingTimeInterval(offset)
                )
            }
            #expect(latest.notificationCandidates.isEmpty)
        }

        var accessoryDetector = HighCPUDetector()
        var accessoryAlertCount = 0
        for offset in stride(from: 0.0, through: 50, by: 10) {
            accessoryAlertCount += accessoryDetector.evaluate(
                apps: [app(cpuPercent: 120, isService: true)],
                preferences: preferences,
                suspendedIdentifiers: [],
                now: start.addingTimeInterval(offset)
            ).notificationCandidates.count
        }
        #expect(accessoryAlertCount == 1)
    }

    @Test("Do Not Disturb suppresses an alert without losing the high CPU streak")
    func doNotDisturbGate() {
        var detector = HighCPUDetector()
        let preferences = alertPreferences()
        for offset in stride(from: 0.0, through: 100, by: 10) {
            let result = detector.evaluate(
                apps: [app(cpuPercent: 120)],
                preferences: preferences,
                suspendedIdentifiers: [],
                isDoNotDisturbEnabled: true,
                now: start.addingTimeInterval(offset)
            )
            #expect(result.notificationCandidates.isEmpty)
        }

        let result = detector.evaluate(
            apps: [app(cpuPercent: 120)],
            preferences: preferences,
            suspendedIdentifiers: [],
            isDoNotDisturbEnabled: false,
            now: start.addingTimeInterval(101)
        )
        #expect(result.notificationCandidates.count == 1)
    }

    @Test("The permanent ignore list suppresses the app until it is cleared")
    func permanentIgnoreList() {
        var detector = HighCPUDetector()
        var preferences = alertPreferences()
        preferences.ignoredHighCPUAlertBundleIdentifiers = ["example.hog"]
        for offset in stride(from: 0.0, through: 100, by: 10) {
            let result = evaluate(
                &detector,
                cpuPercent: 120,
                at: offset,
                preferences: preferences
            )
            #expect(result.notificationCandidates.isEmpty)
        }

        preferences.ignoredHighCPUAlertBundleIdentifiers.removeAll()
        #expect(evaluate(
            &detector,
            cpuPercent: 120,
            at: 101,
            preferences: preferences
        ).notificationCandidates.count == 1)
    }

    @Test("The reminder mute prevents repeat alerts for ten minutes")
    func reminderMute() throws {
        var detector = HighCPUDetector()
        let preferences = alertPreferences()
        var firstAlert: HighCPUAlert?
        for offset in stride(from: 0.0, through: 50, by: 10) {
            firstAlert = evaluate(
                &detector,
                cpuPercent: 120,
                at: offset,
                preferences: preferences
            ).notificationCandidates.first ?? firstAlert
        }
        let alert = try #require(firstAlert)
        detector.mute(
            processIdentity: alert.processIdentity,
            for: preferences.notificationCooldown,
            now: start.addingTimeInterval(50)
        )

        for offset in stride(from: 60.0, through: 640, by: 10) {
            let result = evaluate(
                &detector,
                cpuPercent: 120,
                at: offset,
                preferences: preferences
            )
            #expect(result.notificationCandidates.isEmpty)
        }
        #expect(evaluate(
            &detector,
            cpuPercent: 120,
            at: 650,
            preferences: preferences
        ).notificationCandidates.count == 1)
    }

    @Test("The bounded queue deduplicates and serializes alerts")
    func boundedQueue() throws {
        var queue = HighCPUAlertQueue()
        let candidates = (0..<40).map { index in
            alert(
                identifier: "example.\(index)",
                pid: pid_t(100 + index),
                cpuPercent: Double(200 - index)
            )
        }

        let accepted = queue.enqueue(candidates)
        #expect(accepted.count == HighCPUAlertQueue.maximumCount)
        #expect(queue.alerts.count == HighCPUAlertQueue.maximumCount)
        #expect(queue.current?.bundleIdentifier == "example.0")
        #expect(queue.enqueue([candidates[0]]).isEmpty)

        let removedAlert = queue.removeCurrent()
        let removed = try #require(removedAlert)
        #expect(removed.bundleIdentifier == "example.0")
        #expect(queue.current?.bundleIdentifier == "example.1")

        let currentIdentity = try #require(queue.current?.processIdentity)
        queue.removeResolvedQueuedAlerts(sustainedProcessIdentities: [currentIdentity])
        #expect(queue.alerts.count == 1)
    }

    private func alertPreferences() -> AppPreferences {
        var preferences = AppPreferences()
        preferences.highCPUAlertsEnabled = true
        return preferences
    }

    private func evaluate(
        _ detector: inout HighCPUDetector,
        cpuPercent: Double,
        at offset: TimeInterval,
        preferences: AppPreferences,
        isFrontmost: Bool = false,
        launchedAt: Date? = nil
    ) -> HighCPUDetectionResult {
        detector.evaluate(
            apps: [app(
                cpuPercent: cpuPercent,
                isFrontmost: isFrontmost,
                launchedAt: launchedAt
            )],
            preferences: preferences,
            suspendedIdentifiers: [],
            now: start.addingTimeInterval(offset)
        )
    }

    private func app(
        cpuPercent: Double,
        isFrontmost: Bool = false,
        isService: Bool = false,
        isBackgroundProcess: Bool = false,
        isCurrentApplication: Bool = false,
        requiresPrivilegedControl: Bool = false,
        isNestedHelper: Bool = false,
        launchedAt: Date? = nil
    ) -> ManagedApp {
        let processStart = launchedAt ?? start.addingTimeInterval(-200)
        let identity = ProcessIdentity(
            pid: 100,
            startTimeMicroseconds: UInt64(processStart.timeIntervalSince1970 * 1_000_000),
            requiresPrivilegedControl: requiresPrivilegedControl
        )
        return ManagedApp(
            bundleIdentifier: "example.hog",
            name: "Example Hog",
            bundleURL: URL(fileURLWithPath: isNestedHelper
                ? "/Applications/Example.app/Contents/Helpers/Example Hog.app"
                : "/Applications/Example Hog.app"),
            processIdentifiers: [identity.pid],
            processIdentities: [identity],
            processSamples: [ManagedProcessSample(
                identity: identity,
                cpuPercent: cpuPercent,
                isMainProcess: true
            )],
            launchedAt: processStart,
            cpuPercent: cpuPercent,
            isFrontmost: isFrontmost,
            isHidden: false,
            isPlayingAudio: false,
            isService: isService,
            isBackgroundProcess: isBackgroundProcess,
            isSystemProcess: false,
            isCurrentApplication: isCurrentApplication,
            status: .normal
        )
    }

    private func alert(
        identifier: String,
        pid: pid_t,
        cpuPercent: Double
    ) -> HighCPUAlert {
        HighCPUAlert(
            bundleIdentifier: identifier,
            displayName: identifier,
            applicationURL: nil,
            processIdentity: ProcessIdentity(
                pid: pid,
                startTimeMicroseconds: UInt64(pid) * 1_000_000
            ),
            cpuPercent: cpuPercent,
            threshold: 95,
            duration: 30
        )
    }
}

@Suite("Do Not Disturb schedule")
struct DoNotDisturbMonitorTests {
    @Test("Explicit and scheduled states suppress custom alerts")
    func explicitAndScheduledStates() {
        #expect(monitor(values: ["doNotDisturb": NSNumber(value: true)]).isEnabled())

        let daytime = monitor(values: [
            "doNotDisturb": NSNumber(value: false),
            "dndStart": NSNumber(value: 9 * 60),
            "dndEnd": NSNumber(value: 17 * 60)
        ])
        #expect(daytime.isEnabled(at: date(hour: 12), calendar: calendar))
        #expect(!daytime.isEnabled(at: date(hour: 18), calendar: calendar))

        let overnight = monitor(values: [
            "dndStart": NSNumber(value: 22 * 60),
            "dndEnd": NSNumber(value: 7 * 60)
        ])
        #expect(overnight.isEnabled(at: date(hour: 23), calendar: calendar))
        #expect(overnight.isEnabled(at: date(hour: 6), calendar: calendar))
        #expect(!overnight.isEnabled(at: date(hour: 12), calendar: calendar))
    }

    @Test("Missing or invalid schedule values do not suppress alerts")
    func invalidSchedule() {
        #expect(!monitor(values: [:]).isEnabled())
        #expect(!monitor(values: [
            "dndStart": NSNumber(value: -1),
            "dndEnd": NSNumber(value: 100)
        ]).isEnabled())
        #expect(!monitor(values: [
            "dndStart": NSNumber(value: 100),
            "dndEnd": NSNumber(value: 100)
        ]).isEnabled())
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func date(hour: Int) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 5,
            hour: hour
        )) ?? .distantPast
    }

    private func monitor(values: [String: NSNumber]) -> DoNotDisturbMonitor {
        DoNotDisturbMonitor { values[$0] }
    }
}
