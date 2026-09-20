import Foundation
import OSLog
import TempraSafety

protocol ProcessCrashWatchdogControlling: Sendable {
    var controlsLimitPulseCadence: Bool { get }
    func prepareToStop(_ processes: Set<ProcessIdentity>) async throws
    func armAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws
    func synchronizeAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws
    func synchronize(_ processes: Set<ProcessIdentity>) async throws
    func disarm() async
}

extension ProcessCrashWatchdogControlling {
    var controlsLimitPulseCadence: Bool { false }
}

/// Journals every stop with the launchd-managed process guardian before the
/// signal goes out, so the guardian can resume the processes if Tempra dies.
actor ProcessCrashWatchdog: ProcessCrashWatchdogControlling {
    private let guardian: ProcessGuardianClient
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.temperapp.Temper",
        category: "ProcessSafety"
    )
    nonisolated let controlsLimitPulseCadence = true

    init(guardian: ProcessGuardianClient = ProcessGuardianClient.shared) {
        self.guardian = guardian
    }

    func prepareToStop(_ processes: Set<ProcessIdentity>) async throws {
        try await guardian.prepare(processes)
    }

    func armAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws {
        try await guardian.armAutomaticResume(intervalsByProcess)
    }

    func synchronizeAutomaticResume(
        _ intervalsByProcess: [ProcessIdentity: TimeInterval]
    ) async throws {
        try await guardian.synchronizeAutomaticResume(intervalsByProcess)
    }

    func synchronize(_ processes: Set<ProcessIdentity>) async throws {
        try await guardian.synchronize(processes)
    }

    func disarm() async {
        do {
            try await guardian.disarm()
        } catch {
            logger.error(
                "Could not disarm process guardian cleanly: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
