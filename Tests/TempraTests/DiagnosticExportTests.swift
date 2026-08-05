import Foundation
import Testing
@testable import Tempra

@Suite("Diagnostic export")
@MainActor
struct DiagnosticExportTests {
    @Test("The report contains process reasons and omits application paths")
    func reportOmitsApplicationPaths() throws {
        let date = Date(timeIntervalSinceReferenceDate: 10)
        let process = ProcessIdentity(pid: 42, startTimeMicroseconds: 100)
        let privateURL = URL(fileURLWithPath: "/PRIVATE-PATH/Example.app")
        let identifier = BackgroundProcessPolicy.identifier(
            command: "/PRIVATE-PATH/bin/example-tool",
            pid: process.pid
        )
        let rule = AppRule(
            bundleIdentifier: identifier,
            displayName: "Example",
            action: .limit,
            applicationURL: privateURL,
            updatedAt: date
        )
        let app = ManagedApp(
            bundleIdentifier: identifier,
            name: "Example",
            bundleURL: privateURL,
            processIdentifiers: [process.pid],
            processIdentities: [process],
            processSamples: [ManagedProcessSample(
                identity: process,
                cpuPercent: 20,
                isMainProcess: true,
                isPlayingAudio: true,
                networkActivity: .active,
                hasCPUMeasurement: false
            )],
            cpuPercent: 20,
            isFrontmost: false,
            isHidden: true,
            isPlayingAudio: false,
            isSystemProcess: false,
            status: .limitedWithProtectedProcesses(10)
        )
        let activityEvents = (0..<205).map { index in
            ActivityEvent(
                date: date.addingTimeInterval(TimeInterval(index)),
                bundleIdentifier: identifier,
                displayName: "Event \(index)",
                kind: .waiting,
                detail: "Waiting"
            )
        }

        let report = TempraDiagnosticReport.build(
            generatedAt: date,
            appVersion: "test",
            isEnabled: true,
            preferences: AppPreferences(),
            automaticProfileID: nil,
            effectiveProfileID: nil,
            privilegedControl: "not-registered",
            lifecycleRestorationFailure: nil,
            rules: [rule.bundleIdentifier: rule],
            apps: [app],
            statuses: [app.bundleIdentifier: app.status],
            protectionReasonsByIdentifier: [app.bundleIdentifier: [
                process: [.networkActivity, .mainProcessLifeline]
            ]],
            activityEvents: activityEvents,
            signalEvents: [],
            limitMeasurements: []
        )
        let data = try report.encodedData()
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(report.formatVersion == 1)
        #expect(report.applications.first?.processes.first?.protectionReasons == [
            "audioPlayback",
            "mainProcessLifeline",
            "missingCPUMeasurement",
            "networkActivity"
        ])
        #expect(report.recentActivity.count == 200)
        #expect(report.recentActivity.first?.displayName == "Event 5")
        #expect(report.rules.first?.bundleIdentifier == "background-process:example-tool")
        #expect(!json.contains("PRIVATE-PATH"))
    }

    @Test("The app store reports a completed diagnostic export")
    func appStoreExportsReport() async throws {
        let suiteName = "TempraDiagnosticExportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let exporter = RecordingDiagnosticExporter()
        let store = try AppStore(
            persistence: AppPersistence(defaults: defaults),
            managementCoordinator: ProcessManagementCoordinator(
                controller: ProcessController(frontmostProvider: { nil }),
                processWatcher: ManagedProcessWatcher(
                    audioMonitor: DiagnosticTestAudioMonitor()
                )
            ),
            monitoringService: DiagnosticTestMonitoringService(),
            launchAtLoginController: DiagnosticTestLaunchAtLoginController(),
            startsMonitoring: false,
            diagnosticExporter: exporter,
            persistenceErrorHandler: { _ in }
        )

        await store.exportDiagnostics()

        #expect(exporter.exportedData != nil)
        #expect(exporter.suggestedFileName?.hasSuffix(".json") == true)
        #expect(store.diagnosticExportStatus == .saved(exporter.resultURL))
        _ = await store.shutdown()
    }
}

@MainActor
private final class RecordingDiagnosticExporter: DiagnosticExporting {
    let resultURL = URL(fileURLWithPath: "/tmp/Tempra-Diagnostics-Test.json")
    private(set) var exportedData: Data?
    private(set) var suggestedFileName: String?

    func export(_ data: Data, suggestedFileName: String) throws -> URL? {
        exportedData = data
        self.suggestedFileName = suggestedFileName
        return resultURL
    }
}

private actor DiagnosticTestAudioMonitor: AudioActivityMonitoring {
    func watch(
        revision: UInt64,
        processIdentifiers: Set<pid_t>,
        onActivityChange: @escaping ActivityHandler
    ) {}

    func stop(revision: UInt64) {}
}

private actor DiagnosticTestMonitoringService: MonitoringServicing {
    func sample(_ request: MonitoringRequest) -> MonitoringSample {
        MonitoringSample(
            generation: request.generation,
            systemCPU: nil,
            apps: nil,
            didRefreshApplications: false,
            powerByIdentifier: [:],
            powerMetricsSupported: false
        )
    }

    func resetApplicationBaseline() {}
    func resetPowerMetrics() {}
    func setTemperatureSamplingInterval(_ interval: TimeInterval?) {}
    func shutdown() {}
}

@MainActor
private final class DiagnosticTestLaunchAtLoginController: LaunchAtLoginControlling {
    var isEnabled = false
    var requiresApproval = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}
