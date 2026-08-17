import Foundation
import TempraSafety

struct ProcessGuardianJournalState: Codable, Equatable {
    static let schemaVersion = ProcessGuardianProtocol.journalSchemaVersion

    let version: Int
    var sessionID: UUID?
    var revision: UInt64
    var owner: WatchdogProcessIdentity?
    var trackedProcesses: [WatchdogProcessIdentity]
    var automaticResumeIntervals: [WatchdogResumeDeadline]

    init(
        version: Int = Self.schemaVersion,
        sessionID: UUID? = nil,
        revision: UInt64 = 0,
        owner: WatchdogProcessIdentity? = nil,
        trackedProcesses: [WatchdogProcessIdentity] = [],
        automaticResumeIntervals: [WatchdogResumeDeadline] = []
    ) {
        self.version = version
        self.sessionID = sessionID
        self.revision = revision
        self.owner = owner
        self.trackedProcesses = trackedProcesses
        self.automaticResumeIntervals = automaticResumeIntervals
    }

    var isValid: Bool {
        let sessionStateIsValid: Bool
        if trackedProcesses.isEmpty {
            sessionStateIsValid = sessionID == nil
                && revision == 0
                && owner == nil
        } else {
            sessionStateIsValid = sessionID != nil
                && revision > 0
                && owner != nil
        }
        guard version == Self.schemaVersion,
              sessionStateIsValid,
              trackedProcesses.count <= ProcessGuardianProtocol.maximumProcessCount,
              automaticResumeIntervals.count
                <= ProcessGuardianProtocol.maximumProcessCount,
              Set(trackedProcesses).count == trackedProcesses.count,
              Set(trackedProcesses.map(\.pid)).count == trackedProcesses.count,
              trackedProcesses.allSatisfy({
                  $0.pid > 1 && $0.startTimeMicroseconds > 0
              }),
              owner.map({
                  $0.pid > 1 && $0.startTimeMicroseconds > 0
              }) != false else {
            return false
        }

        let tracked = Set(trackedProcesses)
        let deadlineProcesses = automaticResumeIntervals.map(\.process)
        return Set(deadlineProcesses).count == deadlineProcesses.count
            && Set(deadlineProcesses.map(\.pid)).count == deadlineProcesses.count
            && Set(deadlineProcesses).isSubset(of: tracked)
            && automaticResumeIntervals.allSatisfy {
                $0.resumeAfterMilliseconds > 0
                    && $0.resumeAfterMilliseconds <= UInt32(Int32.max)
            }
    }
}

enum ProcessGuardianJournalError: LocalizedError {
    case invalidState
    case stateTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidState:
            "The process guardian journal is invalid."
        case .stateTooLarge:
            "The process guardian journal is too large."
        }
    }
}

struct ProcessGuardianJournalStore {
    let fileURL: URL

    static func live() throws -> Self {
        let applicationSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return Self(fileURL: applicationSupportURL
            .appendingPathComponent(
                ProcessGuardianProtocol.applicationIdentifier,
                isDirectory: true
            )
            .appendingPathComponent(ProcessGuardianProtocol.journalFileName))
    }

    func load() throws -> ProcessGuardianJournalState {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch let error as CocoaError where
            error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return ProcessGuardianJournalState()
        }

        let data: Data
        do {
            data = try handle.read(
                upToCount: ProcessGuardianProtocol.maximumFrameBytes + 1
            ) ?? Data()
        } catch {
            let readError = error
            do {
                try handle.close()
            } catch {
                throw error
            }
            throw readError
        }
        try handle.close()

        guard data.count <= ProcessGuardianProtocol.maximumFrameBytes else {
            throw ProcessGuardianJournalError.stateTooLarge
        }
        guard !data.isEmpty,
              let state = try? JSONDecoder().decode(
                  ProcessGuardianJournalState.self,
                  from: data
              ),
              state.isValid else {
            throw ProcessGuardianJournalError.invalidState
        }
        return state
    }

    func save(_ state: ProcessGuardianJournalState) throws {
        guard state.isValid else {
            throw ProcessGuardianJournalError.invalidState
        }
        let data = try JSONEncoder().encode(state)
        guard data.count <= ProcessGuardianProtocol.maximumFrameBytes else {
            throw ProcessGuardianJournalError.stateTooLarge
        }

        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )

        let handle = try FileHandle(forWritingTo: fileURL)
        var synchronizationError: (any Error)?
        do {
            try handle.synchronize()
        } catch {
            synchronizationError = error
        }
        do {
            try handle.close()
        } catch {
            if synchronizationError == nil {
                synchronizationError = error
            }
        }
        if let synchronizationError {
            throw synchronizationError
        }
    }
}
